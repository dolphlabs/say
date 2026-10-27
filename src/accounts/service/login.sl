import "strings";
import "timez";
import "../domain" as domain;

pub gc struct Session {
    account_id: str,
    token_hash: bytes
}

// Runs a real verify against a fixed hash, so "no such account" costs the
// same as "wrong password".
fn burn_verify[C](a: Auth[C], password: str) {
    let _r = verify_with(a.hasher, password, a.cfg.dummy_hash);
}

fn invalid_credentials() -> Failed {
    return fail(Why.InvalidCredentials, "");
}

fn rehash[C](a: Auth[C], account_id: str, password: str) {
    let hr = hash_with(a.hasher, password);
    guard let h = hr else {
        return;
    }
    let set = a.store.set_password_hash;
    let _r = set(a.store.context, account_id, h, password_algo(), password_params());
}

pub fn login[C](a: Auth[C], raw_email: str, password: str, meta: Meta) -> result[SignedIn, Failed] {
    let email = domain.normalize_email(raw_email);
    if let limited = allow(a, rule_login_ip(), meta.ip) {
        return err(limited);
    }
    if let limited = allow(a, rule_login_email(), email) {
        return err(limited);
    }
    if len(email) == 0 || len(email) > 254 || len(password) == 0 || len(password) > domain.max_password_bytes() {
        return err(invalid_credentials());
    }
    let find = a.store.find_login;
    let r = find(a.store.context, email);
    guard let found = r else let f = err_of(r) {
        return err(from_store(f));
    }
    guard let row = found else {
        burn_verify(a, password);
        audit_event(a, "", "login_failed", meta, "{\"reason\":\"unknown\"}");
        return err(invalid_credentials());
    }
    guard let encoded = row.password_hash else {
        burn_verify(a, password);
        audit_event(a, row.account_id, "login_failed", meta, "{\"reason\":\"no_password\"}");
        return err(invalid_credentials());
    }
    let vr = verify_with(a.hasher, password, encoded);
    guard let matched = vr else let e = err_of(vr) {
        return err(hash_failure(e));
    }
    if !matched {
        audit_event(a, row.account_id, "login_failed", meta, "{\"reason\":\"password\"}");
        return err(invalid_credentials());
    }
    if row.status == domain.status_unverified() {
        let tr = new_token();
        guard let token = tr else let e = err_of(tr) {
            return err(fail(Why.Unavailable, e));
        }
        let issue = a.store.issue_signup_token;
        let ir = issue(a.store.context, row.account_id, token.hash, a.cfg.signup_ttl_seconds);
        guard let _i = ir else let f = err_of(ir) {
            return err(from_store(f));
        }
        let nv = fail(Why.EmailNotVerified, "");
        nv.signup_token = token.value;
        return err(nv);
    }
    if !domain.can_sign_in(row.status) {
        audit_event(a, row.account_id, "login_failed", meta, "{\"reason\":\"status\"}");
        return err(invalid_credentials());
    }
    let sr = start_session(a, row.account_id, meta);
    guard let token_value = sr else let f = err_of(sr) {
        return err(f);
    }
    if argon_needs_rehash(encoded) {
        spawn rehash(a, row.account_id, password);
    }
    let ar = account_of(a, row.account_id);
    guard let account = ar else let f = err_of(ar) {
        return err(f);
    }
    audit_event(a, row.account_id, "login", meta, "{}");
    let none_grant = account_grant_none();
    return ok(SignedIn { account: account, session_token: token_value, grant: none_grant });
}

fn start_session[C](a: Auth[C], account_id: str, meta: Meta) -> result[str, Failed] {
    let tr = new_token();
    guard let token = tr else let e = err_of(tr) {
        return err(fail(Why.Unavailable, e));
    }
    let create = a.store.create_session;
    let cr = create(a.store.context, account_id, new_session(token, a.cfg.session_ttl_seconds, meta));
    guard let _c = cr else let f = err_of(cr) {
        return err(from_store(f));
    }
    return ok(token.value);
}

pub fn account_of[C](a: Auth[C], account_id: str) -> result[domain.Account, Failed] {
    let f = a.store.account;
    let r = f(a.store.context, account_id);
    guard let found = r else let sf = err_of(r) {
        return err(from_store(sf));
    }
    guard let account = found else {
        return err(fail(Why.Unauthenticated, "account gone"));
    }
    return ok(account);
}

// Redis first (a few hundred microseconds), Postgres on a miss or when
// Redis is down. Only live sessions of active accounts are ever cached,
// for no longer than they have left, and revocation deletes the entry.
pub fn authenticate[C](a: Auth[C], token: str) -> result[opt[Session], Failed] {
    let none_session: opt[Session] = none;
    if len(token) == 0 || len(token) > 128 {
        return ok(none_session);
    }
    let h = hash_token(token);
    let key = session_cache_key(h);
    let get = a.store.eph_get;
    let cached = get(a.store.context, key);
    if let hit = cached {
        if let v = hit {
            let parts = strings.split(v, "|");
            if len(parts) == 2 && (to_int(parts[1]) ?? 0) > timez.now().unix() {
                touch(a, h);
                return ok(some(Session { account_id: parts[0], token_hash: h }));
            }
        }
    }
    let lookup = a.store.session_lookup;
    let r = lookup(a.store.context, h);
    guard let found = r else let f = err_of(r) {
        return err(from_store(f));
    }
    guard let row = found else {
        return ok(none_session);
    }
    if !domain.can_sign_in(row.status) {
        return ok(none_session);
    }
    let left = seconds_until(row.expires_at);
    if left <= 0 {
        return ok(none_session);
    }
    let ttl = left;
    if ttl > 3600 {
        ttl = 3600;
    }
    let put = a.store.eph_put;
    let _p = put(a.store.context, key, row.account_id + "|" + to_str(row.expires_at.unix()), ttl);
    touch(a, h);
    return ok(some(Session { account_id: row.account_id, token_hash: h }));
}

fn touch_now[C](a: Auth[C], h: bytes) {
    let t = a.store.touch_session;
    let _r = t(a.store.context, h);
}

// last_seen_at at most once per 5 minutes per session, decided by Redis.
fn touch[C](a: Auth[C], h: bytes) {
    let gate = a.store.eph_put_nx;
    let r = gate(a.store.context, session_cache_key(h) + ":seen", "1", 300);
    if let first = r {
        if first {
            spawn touch_now(a, h);
        }
    }
}

pub fn forget_sessions[C](a: Auth[C], hashes: [bytes]) {
    if len(hashes) == 0 {
        return;
    }
    let keys: [str] = [];
    for h in hashes {
        push(keys, session_cache_key(h));
    }
    let drop = a.store.eph_drop;
    let r = drop(a.store.context, keys);
    if let _n = r {
    } else let e = err_of(r) {
        report(a, "session cache not cleared, entries expire within the hour: " + e);
    }
}

pub fn logout[C](a: Auth[C], s: Session, meta: Meta) -> result[bool, Failed] {
    let revoke = a.store.revoke_session;
    let r = revoke(a.store.context, s.token_hash);
    guard let _ok = r else let f = err_of(r) {
        return err(from_store(f));
    }
    forget_sessions(a, [s.token_hash]);
    audit_event(a, s.account_id, "logout", meta, "{}");
    return ok(true);
}

pub fn logout_others[C](a: Auth[C], s: Session, meta: Meta) -> result[int, Failed] {
    let revoke = a.store.revoke_others;
    let r = revoke(a.store.context, s.account_id, s.token_hash);
    guard let revoked = r else let f = err_of(r) {
        return err(from_store(f));
    }
    forget_sessions(a, revoked);
    audit_event(a, s.account_id, "logout_others", meta, "{\"sessions\":" + to_str(len(revoked)) + "}");
    return ok(len(revoked));
}

pub fn change_password[C](a: Auth[C], s: Session, current: str, new_password: str,
                          meta: Meta) -> result[int, Failed] {
    if let p = domain.password_problem(new_password) {
        return err(fail_field(Why.WeakPassword, "new_password", p));
    }
    if len(current) == 0 || len(current) > domain.max_password_bytes() {
        return err(invalid_credentials());
    }
    let get = a.store.password_hash_of;
    let r = get(a.store.context, s.account_id);
    guard let found = r else let f = err_of(r) {
        return err(from_store(f));
    }
    guard let encoded = found else {
        burn_verify(a, current);
        return err(invalid_credentials());
    }
    let vr = verify_with(a.hasher, current, encoded);
    guard let matched = vr else let e = err_of(vr) {
        return err(hash_failure(e));
    }
    if !matched {
        audit_event(a, s.account_id, "password_change_failed", meta, "{}");
        return err(invalid_credentials());
    }
    let hr = hash_with(a.hasher, new_password);
    guard let h = hr else let e = err_of(hr) {
        return err(hash_failure(e));
    }
    let change = a.store.change_password;
    let cr = change(a.store.context, s.account_id, h, password_algo(), password_params(), s.token_hash);
    guard let revoked = cr else let f = err_of(cr) {
        return err(from_store(f));
    }
    forget_sessions(a, revoked);
    audit_event(a, s.account_id, "password_changed", meta, "{}");
    return ok(len(revoked));
}

pub fn unlink_google[C](a: Auth[C], s: Session, meta: Meta) -> result[bool, Failed] {
    let f = a.store.unlink_google;
    let r = f(a.store.context, s.account_id);
    guard let _ok = r else let sf = err_of(r) {
        return err(from_store(sf));
    }
    audit_event(a, s.account_id, "google_unlinked", meta, "{}");
    return ok(true);
}

// A flag for now: status DELETED and every session revoked. Anonymising
// the username on leaderboards and purging data come with that feature.
pub fn delete_account[C](a: Auth[C], s: Session, meta: Meta) -> result[bool, Failed] {
    let f = a.store.delete_account;
    let r = f(a.store.context, s.account_id);
    guard let revoked = r else let sf = err_of(r) {
        return err(from_store(sf));
    }
    forget_sessions(a, revoked);
    audit_event(a, s.account_id, "account_deleted", meta, "{}");
    return ok(true);
}

// The operator roles an account holds (admin, super_admin).
pub fn roles_of[C](a: Auth[C], account_id: str) -> result[[str], Failed] {
    let f = a.store.roles_of;
    let r = f(a.store.context, account_id);
    guard let roles = r else let e = err_of(r) {
        return err(from_store(e));
    }
    return ok(roles);
}

// Operator bootstrap (the CLI); the admin UI for roles is prompt 10.
pub fn grant_role[C](a: Auth[C], account_id: str, role: str) -> result[bool, Failed] {
    if role != "admin" && role != "super_admin" {
        return err(fail(Why.BadRequest, "role must be admin or super_admin"));
    }
    let f = a.store.grant_role;
    let r = f(a.store.context, account_id, role);
    guard let granted = r else let e = err_of(r) {
        return err(from_store(e));
    }
    return ok(granted);
}

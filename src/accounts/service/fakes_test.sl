import "encoding";
import "strings";
import "timez";
import "zokor";
import "../domain" as domain;
import "../../ledger/domain" as ledger;

gc struct FakeAccount {
    id: str,
    username: str,
    email: str,
    status: str,
    hash: opt[str],
    google_sub: str
}

gc struct FakeCode {
    hmac: bytes,
    attempts: int,
    consumed: bool,
    expired: bool
}

gc struct FakeSession {
    account_id: str,
    revoked: bool
}

gc struct Fake {
    lock: mutex,
    accounts: map[str]FakeAccount,
    codes: map[str]FakeCode,
    signup_tokens: map[str]str,
    sessions: map[str]FakeSession,
    eph: map[str]str,
    eph_down: bool,
    db_down: bool,
    outbox: map[str]str,
    outbox_sent: [str],
    audit: [AuditEvent],
    last_send: map[str]int,
    grants: map[str]int,
    season_active: bool,
    next_outbox: int,
    id_token: str
}

fn new_fake() -> Fake {
    let accounts: map[str]FakeAccount = {};
    let codes: map[str]FakeCode = {};
    let tokens: map[str]str = {};
    let sessions: map[str]FakeSession = {};
    let eph: map[str]str = {};
    let outbox: map[str]str = {};
    let sent: [str] = [];
    let audit: [AuditEvent] = [];
    let last: map[str]int = {};
    let grants: map[str]int = {};
    return Fake {
        lock: make_mutex(), accounts: accounts, codes: codes, signup_tokens: tokens, sessions: sessions,
        eph: eph, eph_down: false, db_down: false, outbox: outbox, outbox_sent: sent, audit: audit,
        last_send: last, grants: grants, season_active: true, next_outbox: 0, id_token: ""
    };
}

fn down() -> StoreFail {
    return StoreFail { fault: Fault.Unavailable, detail: "db down", retry_after: 0 };
}

fn hx(b: bytes) -> str {
    return encoding.hex_encode(b);
}

fn as_account(f: FakeAccount) -> domain.Account {
    let email: opt[str] = some(f.email);
    let has_password = false;
    if let _h = f.hash {
        has_password = true;
    }
    return domain.Account {
        id: f.id, username: f.username, email: email, status: f.status,
        email_verified: f.status == "ACTIVE", has_password: has_password,
        google_linked: len(f.google_sub) > 0,
        username_changeable_at: timez.unix(0), created_at: timez.unix(0)
    };
}

fn find_by_email(f: Fake, email: str) -> opt[FakeAccount] {
    for id, a in f.accounts {
        if a.email == email {
            return some(a);
        }
    }
    return none;
}

fn f_usernames_taken(f: Fake, names: [str]) -> result[[str], StoreFail] {
    if f.db_down { return err(down()); }
    let out: [str] = [];
    mutex_lock(f.lock);
    for id, a in f.accounts {
        for n in names {
            if a.username == n { push(out, n); }
        }
    }
    mutex_unlock(f.lock);
    return ok(out);
}

fn add_outbox(f: Fake, payload: str) -> str {
    f.next_outbox += 1;
    let id = "ob" + to_str(f.next_outbox);
    f.outbox[id] = payload;
    return id;
}

fn f_create_signup(f: Fake, s: NewSignup) -> result[CodeSent, StoreFail] {
    if f.db_down { return err(down()); }
    mutex_lock(f.lock);
    for id, a in f.accounts {
        if a.username == s.username {
            mutex_unlock(f.lock);
            return err(StoreFail { fault: Fault.UsernameTaken, detail: "", retry_after: 0 });
        }
        if a.email == s.email {
            mutex_unlock(f.lock);
            return err(StoreFail { fault: Fault.EmailTaken, detail: "", retry_after: 0 });
        }
    }
    f.accounts[s.account_id] = FakeAccount { id: s.account_id, username: s.username, email: s.email, status: "UNVERIFIED", hash: some(s.password_hash), google_sub: "" };
    f.codes[s.account_id + "|verify_email"] = FakeCode { hmac: s.code_hmac, attempts: 0, consumed: false, expired: false };
    f.signup_tokens[hx(s.signup_token_hash)] = s.account_id;
    let ob = add_outbox(f, s.outbox_payload);
    f.last_send[s.email] = timez.now().unix();
    mutex_unlock(f.lock);
    return ok(CodeSent { outbox_id: ob, resend_available_at: timez.now().add(60 * timez.SECOND) });
}

fn f_replace_code(f: Fake, c: NewCode) -> result[CodeSent, StoreFail] {
    if f.db_down { return err(down()); }
    mutex_lock(f.lock);
    let now = timez.now().unix();
    if has(f.last_send, c.email) && now - f.last_send[c.email] < c.cooldown_seconds {
        let wait = c.cooldown_seconds - (now - f.last_send[c.email]);
        mutex_unlock(f.lock);
        return err(StoreFail { fault: Fault.CoolingDown, detail: "", retry_after: wait });
    }
    f.codes[c.account_id + "|" + c.purpose] = FakeCode { hmac: c.code_hmac, attempts: 0, consumed: false, expired: false };
    let ob = add_outbox(f, c.outbox_payload);
    f.last_send[c.email] = now;
    mutex_unlock(f.lock);
    return ok(CodeSent { outbox_id: ob, resend_available_at: timez.now().add(60 * timez.SECOND) });
}

fn f_signup_account(f: Fake, h: bytes) -> result[opt[Pending], StoreFail] {
    if f.db_down { return err(down()); }
    let none_p: opt[Pending] = none;
    mutex_lock(f.lock);
    let key = hx(h);
    if !has(f.signup_tokens, key) {
        mutex_unlock(f.lock);
        return ok(none_p);
    }
    let a = f.accounts[f.signup_tokens[key]];
    mutex_unlock(f.lock);
    return ok(some(Pending { account_id: a.id, username: a.username, email: a.email, status: a.status }));
}

fn f_issue_signup_token(f: Fake, account_id: str, h: bytes, ttl: int) -> result[bool, StoreFail] {
    mutex_lock(f.lock);
    f.signup_tokens[hx(h)] = account_id;
    mutex_unlock(f.lock);
    return ok(true);
}

// The shared code check: the same rules the SQL applies under FOR UPDATE.
fn use_code(f: Fake, u: CodeUse) -> CodeCheck {
    let key = u.account_id + "|" + u.purpose;
    if !has(f.codes, key) {
        return CodeCheck.Missing;
    }
    let c = f.codes[key];
    if c.consumed {
        return CodeCheck.Missing;
    }
    if c.attempts >= domain.otp_max_attempts() {
        return CodeCheck.Locked;
    }
    if c.expired {
        return CodeCheck.Expired;
    }
    if !zokor.constant_time_equal(c.hmac, u.code_hmac) {
        c.attempts += 1;
        return CodeCheck.Wrong;
    }
    c.consumed = true;
    return CodeCheck.Matched;
}

fn left_for(f: Fake, u: CodeUse) -> int {
    let key = u.account_id + "|" + u.purpose;
    if !has(f.codes, key) {
        return 0;
    }
    return domain.attempts_left(f.codes[key].attempts);
}

fn f_verify_email(f: Fake, v: VerifyEmail) -> result[Verified, StoreFail] {
    if f.db_down { return err(down()); }
    let none_a: opt[domain.Account] = none;
    let none_g: opt[ledger.Grant] = none;
    mutex_lock(f.lock);
    let check = use_code(f, v.code);
    if check != CodeCheck.Matched {
        let left = left_for(f, v.code);
        mutex_unlock(f.lock);
        return ok(Verified { check: check, attempts_left: left, account: none_a, grant: none_g });
    }
    let a = f.accounts[v.code.account_id];
    a.status = "ACTIVE";
    let grant = none_g;
    if f.season_active {
        if !has(f.grants, a.id) {
            f.grants[a.id] = 1000;
        }
        grant = some(ledger.Grant { amount: f.grants[a.id], season_ordinal: 1, season_ends_at: timez.unix(2000000000) });
    }
    f.sessions[hx(v.session.token_hash)] = FakeSession { account_id: a.id, revoked: false };
    mutex_unlock(f.lock);
    return ok(Verified { check: check, attempts_left: 5, account: some(as_account(a)), grant: grant });
}

fn revoke_all(f: Fake, account_id: str, keep: str) -> [bytes] {
    let out: [bytes] = [];
    for k, s in f.sessions {
        if s.account_id == account_id && !s.revoked && k != keep {
            s.revoked = true;
            push(out, encoding.hex_decode(k) ?? b"");
        }
    }
    return out;
}

fn f_reset_password(f: Fake, r: ResetPassword) -> result[ResetDone, StoreFail] {
    if f.db_down { return err(down()); }
    let none_b: [bytes] = [];
    mutex_lock(f.lock);
    let check = use_code(f, r.code);
    if check != CodeCheck.Matched {
        let left = left_for(f, r.code);
        mutex_unlock(f.lock);
        return ok(ResetDone { check: check, attempts_left: left, revoked: none_b });
    }
    let a = f.accounts[r.code.account_id];
    a.hash = some(r.password_hash);
    let revoked = revoke_all(f, a.id, "");
    mutex_unlock(f.lock);
    return ok(ResetDone { check: check, attempts_left: 5, revoked: revoked });
}

fn f_find_login(f: Fake, email: str) -> result[opt[LoginRow], StoreFail] {
    if f.db_down { return err(down()); }
    let none_r: opt[LoginRow] = none;
    mutex_lock(f.lock);
    let found = find_by_email(f, email);
    mutex_unlock(f.lock);
    guard let a = found else { return ok(none_r); }
    return ok(some(LoginRow { account_id: a.id, username: a.username, email: a.email, status: a.status, password_hash: a.hash }));
}

fn f_set_password_hash(f: Fake, id: str, h: str, algo: str, params: str) -> result[bool, StoreFail] {
    mutex_lock(f.lock);
    f.accounts[id].hash = some(h);
    mutex_unlock(f.lock);
    return ok(true);
}

fn f_create_session(f: Fake, id: str, s: NewSession) -> result[bool, StoreFail] {
    if f.db_down { return err(down()); }
    mutex_lock(f.lock);
    f.sessions[hx(s.token_hash)] = FakeSession { account_id: id, revoked: false };
    mutex_unlock(f.lock);
    return ok(true);
}

fn f_session_lookup(f: Fake, h: bytes) -> result[opt[SessionRow], StoreFail] {
    if f.db_down { return err(down()); }
    let none_r: opt[SessionRow] = none;
    mutex_lock(f.lock);
    let key = hx(h);
    if !has(f.sessions, key) || f.sessions[key].revoked {
        mutex_unlock(f.lock);
        return ok(none_r);
    }
    let s = f.sessions[key];
    let status = f.accounts[s.account_id].status;
    mutex_unlock(f.lock);
    return ok(some(SessionRow { session_id: key, account_id: s.account_id, status: status, expires_at: timez.now().add(3600 * timez.SECOND) }));
}

fn f_revoke_session(f: Fake, h: bytes) -> result[bool, StoreFail] {
    mutex_lock(f.lock);
    let key = hx(h);
    if has(f.sessions, key) { f.sessions[key].revoked = true; }
    mutex_unlock(f.lock);
    return ok(true);
}

fn f_revoke_others(f: Fake, id: str, keep: bytes) -> result[[bytes], StoreFail] {
    mutex_lock(f.lock);
    let out = revoke_all(f, id, hx(keep));
    mutex_unlock(f.lock);
    return ok(out);
}

fn f_touch(f: Fake, h: bytes) -> result[bool, StoreFail] {
    return ok(true);
}

fn f_account(f: Fake, id: str) -> result[opt[domain.Account], StoreFail] {
    if f.db_down { return err(down()); }
    let none_a: opt[domain.Account] = none;
    mutex_lock(f.lock);
    if !has(f.accounts, id) {
        mutex_unlock(f.lock);
        return ok(none_a);
    }
    let a = as_account(f.accounts[id]);
    mutex_unlock(f.lock);
    return ok(some(a));
}

fn f_password_hash_of(f: Fake, id: str) -> result[opt[str], StoreFail] {
    mutex_lock(f.lock);
    let h = f.accounts[id].hash;
    mutex_unlock(f.lock);
    return ok(h);
}

fn f_change_password(f: Fake, id: str, h: str, algo: str, params: str, keep: bytes) -> result[[bytes], StoreFail] {
    mutex_lock(f.lock);
    f.accounts[id].hash = some(h);
    let out = revoke_all(f, id, hx(keep));
    mutex_unlock(f.lock);
    return ok(out);
}

fn f_unlink_google(f: Fake, id: str) -> result[bool, StoreFail] {
    mutex_lock(f.lock);
    let a = f.accounts[id];
    let has_password = false;
    if let _h = a.hash { has_password = true; }
    if !domain.can_unlink_google(has_password) {
        mutex_unlock(f.lock);
        return err(StoreFail { fault: Fault.LastSignInMethod, detail: "", retry_after: 0 });
    }
    a.google_sub = "";
    mutex_unlock(f.lock);
    return ok(true);
}

fn f_grant_role(f: Fake, id: str, role: str) -> result[bool, StoreFail] {
    if !has(f.accounts, id) {
        return err(StoreFail { fault: Fault.NotFound, detail: "account", retry_after: 0 });
    }
    return ok(true);
}

fn f_roles_of(f: Fake, id: str) -> result[[str], StoreFail] {
    let out: [str] = [];
    if id == "admin-1" {
        push(out, "admin");
    }
    return ok(out);
}

fn f_delete_account(f: Fake, id: str) -> result[[bytes], StoreFail] {
    mutex_lock(f.lock);
    f.accounts[id].status = "DELETED";
    let out = revoke_all(f, id, "");
    mutex_unlock(f.lock);
    return ok(out);
}

fn f_identity_owner(f: Fake, sub: str) -> result[opt[str], StoreFail] {
    let none_s: opt[str] = none;
    mutex_lock(f.lock);
    for id, a in f.accounts {
        if a.google_sub == sub {
            mutex_unlock(f.lock);
            return ok(some(id));
        }
    }
    mutex_unlock(f.lock);
    return ok(none_s);
}

fn f_email_owner(f: Fake, email: str) -> result[opt[str], StoreFail] {
    let none_s: opt[str] = none;
    mutex_lock(f.lock);
    let found = find_by_email(f, email);
    mutex_unlock(f.lock);
    guard let a = found else { return ok(none_s); }
    return ok(some(a.id));
}

fn f_create_google(f: Fake, g: GoogleSignup) -> result[Created, StoreFail] {
    mutex_lock(f.lock);
    let none_h: opt[str] = none;
    f.accounts[g.account_id] = FakeAccount { id: g.account_id, username: g.username, email: g.email, status: "ACTIVE", hash: none_h, google_sub: g.subject };
    f.grants[g.account_id] = 1000;
    f.sessions[hx(g.session.token_hash)] = FakeSession { account_id: g.account_id, revoked: false };
    let a = as_account(f.accounts[g.account_id]);
    mutex_unlock(f.lock);
    return ok(Created { account: a, grant: some(ledger.Grant { amount: 1000, season_ordinal: 1, season_ends_at: timez.unix(2000000000) }) });
}

fn f_link_google(f: Fake, id: str, sub: str, email: str) -> result[bool, StoreFail] {
    mutex_lock(f.lock);
    f.accounts[id].google_sub = sub;
    mutex_unlock(f.lock);
    return ok(true);
}

fn f_insert_audit(f: Fake, evs: [AuditEvent]) -> result[int, str] {
    mutex_lock(f.lock);
    for e in evs { push(f.audit, e); }
    mutex_unlock(f.lock);
    return ok(len(evs));
}

fn f_claim_outbox(f: Fake, id: str, limit: int, lease: int) -> result[[OutboxItem], str] {
    let out: [OutboxItem] = [];
    mutex_lock(f.lock);
    for k, p in f.outbox {
        if (id == "" || id == k) && len(out) < limit {
            push(out, OutboxItem { id: k, kind: "otp_email", payload: p, attempts: 1 });
        }
    }
    mutex_unlock(f.lock);
    return ok(out);
}

fn f_outbox_sent(f: Fake, id: str) -> result[bool, str] {
    mutex_lock(f.lock);
    del(f.outbox, id);
    push(f.outbox_sent, id);
    mutex_unlock(f.lock);
    return ok(true);
}

fn f_outbox_retry(f: Fake, id: str, e: str, delay: int) -> result[bool, str] {
    return ok(true);
}

fn f_sweep(f: Fake) -> result[int, str] {
    return ok(0);
}

fn eph_err(f: Fake) -> opt[str] {
    if f.eph_down {
        return some("redis down");
    }
    return none;
}

fn f_eph_put_nx(f: Fake, k: str, v: str, secs: int) -> result[bool, str] {
    if let e = eph_err(f) { return err(e); }
    mutex_lock(f.lock);
    if has(f.eph, k) {
        mutex_unlock(f.lock);
        return ok(false);
    }
    f.eph[k] = v;
    mutex_unlock(f.lock);
    return ok(true);
}

fn f_eph_put(f: Fake, k: str, v: str, secs: int) -> result[bool, str] {
    if let e = eph_err(f) { return err(e); }
    mutex_lock(f.lock);
    f.eph[k] = v;
    mutex_unlock(f.lock);
    return ok(true);
}

fn f_eph_get(f: Fake, k: str) -> result[opt[str], str] {
    if let e = eph_err(f) { return err(e); }
    let none_s: opt[str] = none;
    mutex_lock(f.lock);
    let v = none_s;
    if has(f.eph, k) { v = some(f.eph[k]); }
    mutex_unlock(f.lock);
    return ok(v);
}

fn f_eph_take(f: Fake, k: str) -> result[opt[str], str] {
    let r = f_eph_get(f, k);
    if let _v = r {
        mutex_lock(f.lock);
        if has(f.eph, k) { del(f.eph, k); }
        mutex_unlock(f.lock);
    }
    return r;
}

fn f_eph_drop(f: Fake, ks: [str]) -> result[int, str] {
    if let e = eph_err(f) { return err(e); }
    mutex_lock(f.lock);
    let n = 0;
    for k in ks {
        if has(f.eph, k) {
            del(f.eph, k);
            n += 1;
        }
    }
    mutex_unlock(f.lock);
    return ok(n);
}

fn f_eph_hit(f: Fake, k: str, window: int) -> result[int, str] {
    if let e = eph_err(f) { return err(e); }
    mutex_lock(f.lock);
    let n = 1;
    if has(f.eph, k) { n = (to_int(f.eph[k]) ?? 0) + 1; }
    f.eph[k] = to_str(n);
    mutex_unlock(f.lock);
    return ok(n);
}

fn f_google_exchange(f: Fake, code: str, verifier: str, redirect: str) -> result[str, str] {
    if len(f.id_token) == 0 {
        return err("google timed out");
    }
    return ok(f.id_token);
}

fn f_google_jwks(f: Fake) -> result[JwksDoc, str] {
    return ok(JwksDoc { body: fixture_jwks(), max_age_seconds: 3600 });
}

fn fake_store(f: Fake) -> AuthStore[Fake] {
    return AuthStore[Fake] {
        context: f,
        usernames_taken: f_usernames_taken,
        create_signup: f_create_signup,
        replace_code: f_replace_code,
        signup_account: f_signup_account,
        issue_signup_token: f_issue_signup_token,
        verify_email: f_verify_email,
        reset_password: f_reset_password,
        find_login: f_find_login,
        set_password_hash: f_set_password_hash,
        create_session: f_create_session,
        session_lookup: f_session_lookup,
        revoke_session: f_revoke_session,
        revoke_others: f_revoke_others,
        touch_session: f_touch,
        account: f_account,
        password_hash_of: f_password_hash_of,
        change_password: f_change_password,
        unlink_google: f_unlink_google,
        delete_account: f_delete_account,
        roles_of: f_roles_of,
        grant_role: f_grant_role,
        identity_owner: f_identity_owner,
        email_owner: f_email_owner,
        create_google_account: f_create_google,
        link_google: f_link_google,
        insert_audit: f_insert_audit,
        claim_outbox: f_claim_outbox,
        outbox_sent: f_outbox_sent,
        outbox_retry: f_outbox_retry,
        sweep_expired: f_sweep,
        eph_put_nx: f_eph_put_nx,
        eph_put: f_eph_put,
        eph_get: f_eph_get,
        eph_take: f_eph_take,
        eph_drop: f_eph_drop,
        eph_hit: f_eph_hit,
        google_exchange: f_google_exchange,
        google_jwks: f_google_jwks
    };
}

// Stand-ins for argon2: deterministic and instant, so tests measure logic.
fn stub_hash(p: str) -> result[str, str] {
    return ok("stub$" + p);
}

fn stub_verify(p: str, enc: str) -> result[bool, str] {
    return ok(enc == "stub$" + p);
}

gc struct Counter {
    lock: mutex,
    n: int
}

fn counter_id() -> str {
    return "acc-" + to_str(timez.now().unix_nano());
}

gc struct Outbox {
    lock: mutex,
    mails: [Mail],
    fail: bool
}

fn new_outbox() -> Outbox {
    let mails: [Mail] = [];
    return Outbox { lock: make_mutex(), mails: mails, fail: false };
}

fn outbox_send(o: Outbox, m: Mail) -> result[bool, str] {
    if o.fail {
        return err("provider down");
    }
    mutex_lock(o.lock);
    push(o.mails, m);
    mutex_unlock(o.lock);
    return ok(true);
}

fn mailer(o: Outbox) -> Mailer[Outbox] {
    return Mailer[Outbox] { context: o, send: outbox_send };
}

fn fake_config() -> AuthConfig {
    return AuthConfig {
        otp_secret: to_bytes("test-otp-secret-0123456789abcdef0123"),
        reserved: ["say", "admin", "support"],
        session_ttl_seconds: 2592000,
        signup_ttl_seconds: 1800,
        hold_seconds: 600,
        pending_seconds: 900,
        oauth_state_seconds: 600,
        google_client_id: "client-1",
        google_redirect_uri: "https://api.say.test/v1/auth/google/callback",
        google_auth_url: "https://accounts.google.com/o/oauth2/v2/auth",
        dummy_hash: "stub$dummy"
    };
}

fn fresh(f: Fake) -> Auth[Fake] {
    return new_auth(fake_store(f), fake_config(), new_hasher(2, 16, stub_hash, stub_verify), counter_id);
}

fn meta() -> Meta {
    return Meta { ip: "10.0.0.1", user_agent: "test" };
}

fn last_code(o: Outbox) -> str {
    mutex_lock(o.lock);
    let n = len(o.mails);
    let c = "";
    if n > 0 {
        c = o.mails[n - 1].code;
    }
    mutex_unlock(o.lock);
    return c;
}

fn contains(s: str, part: str) -> bool {
    return strings.contains(s, part);
}

import "json";
import "pg";
import "strings";
import "time";
import "timez";
import "zokor";
import "../domain" as domain;
import "../service" as service;
import "../../ledger/store" as ledger_store;

fn pg_deadline(s: Store) -> until {
    return until_of(time.mono() + s.pg_timeout);
}

fn unavailable(e: str) -> service.StoreFail {
    return service.StoreFail { fault: service.Fault.Unavailable, detail: e, retry_after: 0 };
}

// Transaction bodies can only fail with a string, so a business outcome
// that must roll back travels as "fault:<name>:<retry_after>" and is
// turned back into a typed fault here; a constraint violation is named by
// its constraint.
fn store_fail(e: str) -> service.StoreFail {
    if strings.has_prefix(e, "fault:") {
        let parts = strings.split(e, ":");
        let retry = 0;
        if len(parts) >= 3 {
            retry = to_int(parts[2]) ?? 0;
        }
        let f = service.Fault.Unavailable;
        switch parts[1] {
            case "cooldown" { f = service.Fault.CoolingDown; }
            case "hourly" { f = service.Fault.HourlyCap; }
            case "last_method" { f = service.Fault.LastSignInMethod; }
            case "not_found" { f = service.Fault.NotFound; }
            default {}
        }
        return service.StoreFail { fault: f, detail: parts[1], retry_after: retry };
    }
    if zokor.is_unique_violation(e) {
        if strings.contains(e, "accounts_username_key") {
            return service.StoreFail { fault: service.Fault.UsernameTaken, detail: "username", retry_after: 0 };
        }
        if strings.contains(e, "accounts_email_key") {
            return service.StoreFail { fault: service.Fault.EmailTaken, detail: "email", retry_after: 0 };
        }
        if strings.contains(e, "auth_identities") {
            return service.StoreFail { fault: service.Fault.IdentityTaken, detail: "identity", retry_after: 0 };
        }
    }
    return unavailable(e);
}

fn exec(c: pg.Conn, sql: str, args: [pg.Arg], d: until) -> result[int, str] {
    let r = pg.query(c, sql, args, d);
    guard let _rows = r else let e = err_of(r) {
        return err(e);
    }
    return ok(0);
}

gc struct IdRow {
    id: str
}

gc struct NameRow {
    username: str
}

gc struct HashRow {
    hash: str
}

gc struct TokenHashRow {
    token_hash: bytes
}

gc struct SentRow {
    id: str,
    resend_available_at: timez.Time
}

fn account_sql() -> str {
    return "select a.id::text as id, a.username::text as username, a.email::text as email, a.status, " +
           "a.email_verified_at is not null as email_verified, " +
           "exists (select 1 from password_credentials p where p.account_id = a.id) as has_password, " +
           "exists (select 1 from auth_identities i where i.account_id = a.id and i.provider = 'google') as google_linked, " +
           "a.username_changeable_at, a.created_at from accounts a where a.id = $1";
}

fn read_account(c: pg.Conn, id: str, d: until) -> result[domain.Account, str] {
    let r: result[[domain.Account], str] = zokor.conn_query_all(c, account_sql(), [pg.arg_text(id)], d);
    guard let rows = r else let e = err_of(r) {
        return err(e);
    }
    if len(rows) != 1 {
        return err("fault:not_found");
    }
    return ok(rows[0]);
}

fn st_account(s: Store, id: str) -> result[opt[domain.Account], service.StoreFail] {
    let r: result[opt[domain.Account], str] = zokor.query_one(s.pg, account_sql(), [pg.arg_text(id)], pg_deadline(s));
    guard let found = r else let e = err_of(r) {
        return err(unavailable(e));
    }
    return ok(found);
}

fn st_usernames_taken(s: Store, names: [str]) -> result[[str], service.StoreFail] {
    let r: result[[NameRow], str] = zokor.query_all(s.pg,
        "select username::text as username from accounts where username = any(string_to_array($1, ',')::citext[])",
        [pg.arg_text(strings.join(names, ","))], pg_deadline(s));
    guard let rows = r else let e = err_of(r) {
        return err(unavailable(e));
    }
    let out: [str] = [];
    for row in rows {
        push(out, row.username);
    }
    return ok(out);
}

fn insert_otp(c: pg.Conn, account_id: str, purpose: str, hmac: bytes, ttl: int, d: until) -> result[int, str] {
    return exec(c,
        "insert into otp_codes (account_id, purpose, code_hmac, expires_at) " +
        "values ($1, $2, $3, now() + make_interval(secs => $4))",
        [pg.arg_text(account_id), pg.arg_text(purpose), pg.arg_bytes(hmac), pg.arg_int(ttl)], d);
}

fn queue_email(c: pg.Conn, email: str, purpose: str, payload: str, cooldown: int, d: until) -> result[service.CodeSent, str] {
    let sr = exec(c, "insert into otp_sends (email, purpose) values ($1, $2)",
                  [pg.arg_text(email), pg.arg_text(purpose)], d);
    guard let _s = sr else let e = err_of(sr) {
        return err(e);
    }
    let r: result[[SentRow], str] = zokor.conn_query_all(c,
        "insert into auth_outbox (kind, payload) values ('otp_email', $1::jsonb) " +
        "returning id::text as id, now() + make_interval(secs => $2) as resend_available_at",
        [pg.arg_text(payload), pg.arg_int(cooldown)], d);
    guard let rows = r else let e = err_of(r) {
        return err(e);
    }
    return ok(service.CodeSent { outbox_id: rows[0].id, resend_available_at: rows[0].resend_available_at });
}

gc struct SignupTx {
    s: Store,
    n: service.NewSignup
}

fn signup_tx(c: pg.Conn, t: SignupTx) -> result[service.CodeSent, str] {
    let d = pg_deadline(t.s);
    let n = t.n;
    let steps = [
        exec(c, "insert into accounts (id, username, email, status, kind) values ($1, $2, $3, 'UNVERIFIED', 'USER')",
             [pg.arg_text(n.account_id), pg.arg_text(n.username), pg.arg_text(n.email)], d),
        exec(c, "insert into password_credentials (account_id, hash, algo, params) values ($1, $2, $3, $4)",
             [pg.arg_text(n.account_id), pg.arg_text(n.password_hash), pg.arg_text(n.password_algo), pg.arg_text(n.password_params)], d)
    ];
    for st in steps {
        guard let _ok = st else let e = err_of(st) {
            return err(e);
        }
    }
    let o = insert_otp(c, n.account_id, domain.purpose_verify_email(), n.code_hmac, n.otp_ttl_seconds, d);
    guard let _o = o else let e = err_of(o) {
        return err(e);
    }
    let tk = exec(c, "insert into signup_tokens (token_hash, account_id, expires_at) values ($1, $2, now() + make_interval(secs => $3))",
                  [pg.arg_bytes(n.signup_token_hash), pg.arg_text(n.account_id), pg.arg_int(n.signup_ttl_seconds)], d);
    guard let _t = tk else let e = err_of(tk) {
        return err(e);
    }
    return queue_email(c, n.email, domain.purpose_verify_email(), n.outbox_payload, domain.resend_cooldown_seconds(), d);
}

fn st_create_signup(s: Store, n: service.NewSignup) -> result[service.CodeSent, service.StoreFail] {
    let r = zokor.transaction(s.pg, SignupTx { s: s, n: n }, signup_tx, pg_deadline(s));
    guard let sent = r else let e = err_of(r) {
        return err(store_fail(e));
    }
    return ok(sent);
}

gc struct WindowRow {
    since_last: opt[int],
    hourly: int,
    oldest_age: opt[int]
}

gc struct CodeTx {
    s: Store,
    n: service.NewCode
}

// Serialised per email by an advisory lock, so two resends racing cannot
// both pass the cooldown, and the partial unique index never sees two
// live codes.
fn code_tx(c: pg.Conn, t: CodeTx) -> result[service.CodeSent, str] {
    let d = pg_deadline(t.s);
    let n = t.n;
    let lk = exec(c, "select pg_advisory_xact_lock(hashtextextended('otp:' || $1, 0))", [pg.arg_text(n.email)], d);
    guard let _l = lk else let e = err_of(lk) {
        return err(e);
    }
    let wr: result[[WindowRow], str] = zokor.conn_query_all(c,
        "select extract(epoch from now() - max(sent_at))::bigint as since_last, count(*)::bigint as hourly, " +
        "extract(epoch from now() - min(sent_at))::bigint as oldest_age " +
        "from otp_sends where email = $1 and sent_at > now() - interval '1 hour'",
        [pg.arg_text(n.email)], d);
    guard let windows = wr else let e = err_of(wr) {
        return err(e);
    }
    let w = windows[0];
    if let since = w.since_last {
        if since < n.cooldown_seconds {
            return err("fault:cooldown:" + to_str(n.cooldown_seconds - since));
        }
    }
    if w.hourly >= n.max_per_hour {
        return err("fault:hourly:" + to_str(3600 - (w.oldest_age ?? 0)));
    }
    let kill = exec(c, "update otp_codes set consumed_at = now() where account_id = $1 and purpose = $2 and consumed_at is null",
                    [pg.arg_text(n.account_id), pg.arg_text(n.purpose)], d);
    guard let _k = kill else let e = err_of(kill) {
        return err(e);
    }
    let o = insert_otp(c, n.account_id, n.purpose, n.code_hmac, n.otp_ttl_seconds, d);
    guard let _o = o else let e = err_of(o) {
        return err(e);
    }
    return queue_email(c, n.email, n.purpose, n.outbox_payload, n.cooldown_seconds, d);
}

fn st_replace_code(s: Store, n: service.NewCode) -> result[service.CodeSent, service.StoreFail] {
    let r = zokor.transaction(s.pg, CodeTx { s: s, n: n }, code_tx, pg_deadline(s));
    guard let sent = r else let e = err_of(r) {
        return err(store_fail(e));
    }
    return ok(sent);
}

fn st_signup_account(s: Store, h: bytes) -> result[opt[service.Pending], service.StoreFail] {
    let r: result[opt[service.Pending], str] = zokor.query_one(s.pg,
        "select a.id::text as account_id, a.username::text as username, a.email::text as email, a.status " +
        "from signup_tokens t join accounts a on a.id = t.account_id " +
        "where t.token_hash = $1 and t.expires_at > now()",
        [pg.arg_bytes(h)], pg_deadline(s));
    guard let found = r else let e = err_of(r) {
        return err(unavailable(e));
    }
    return ok(found);
}

fn st_issue_signup_token(s: Store, account_id: str, h: bytes, ttl: int) -> result[bool, service.StoreFail] {
    let r = pg.pool_query(s.pg,
        "insert into signup_tokens (token_hash, account_id, expires_at) values ($1, $2, now() + make_interval(secs => $3))",
        [pg.arg_bytes(h), pg.arg_text(account_id), pg.arg_int(ttl)], pg_deadline(s));
    guard let _r = r else let e = err_of(r) {
        return err(unavailable(e));
    }
    return ok(true);
}

gc struct CodeRow {
    id: str,
    code_hmac: bytes,
    attempts: int,
    expired: bool
}

gc struct AttemptsRow {
    attempts: int
}

gc struct CodeOutcome {
    check: service.CodeCheck,
    attempts_left: int
}

// The live code row is locked for the rest of the transaction: of twenty
// concurrent correct guesses one consumes it, and the rest find it gone.
fn use_code(c: pg.Conn, u: service.CodeUse, d: until) -> result[CodeOutcome, str] {
    let r: result[[CodeRow], str] = zokor.conn_query_all(c,
        "select id::text as id, code_hmac, attempts, expires_at <= now() as expired from otp_codes " +
        "where account_id = $1 and purpose = $2 and consumed_at is null for update",
        [pg.arg_text(u.account_id), pg.arg_text(u.purpose)], d);
    guard let rows = r else let e = err_of(r) {
        return err(e);
    }
    if len(rows) == 0 {
        return ok(CodeOutcome { check: service.CodeCheck.Missing, attempts_left: 0 });
    }
    let row = rows[0];
    let state = domain.otp_state(row.attempts, row.expired, false);
    if state == domain.OtpState.Locked {
        return ok(CodeOutcome { check: service.CodeCheck.Locked, attempts_left: 0 });
    }
    if state == domain.OtpState.Expired {
        return ok(CodeOutcome { check: service.CodeCheck.Expired, attempts_left: 0 });
    }
    if !zokor.constant_time_equal(row.code_hmac, u.code_hmac) {
        let ar: result[[AttemptsRow], str] = zokor.conn_query_all(c,
            "update otp_codes set attempts = attempts + 1 where id = $1 returning attempts",
            [pg.arg_text(row.id)], d);
        guard let after = ar else let e = err_of(ar) {
            return err(e);
        }
        return ok(CodeOutcome { check: service.CodeCheck.Wrong, attempts_left: domain.attempts_left(after[0].attempts) });
    }
    let used = exec(c, "update otp_codes set consumed_at = now() where id = $1", [pg.arg_text(row.id)], d);
    guard let _u = used else let e = err_of(used) {
        return err(e);
    }
    return ok(CodeOutcome { check: service.CodeCheck.Matched, attempts_left: domain.attempts_left(row.attempts) });
}

fn insert_session(c: pg.Conn, account_id: str, n: service.NewSession, d: until) -> result[int, str] {
    return exec(c,
        "insert into sessions (account_id, token_hash, expires_at, ip, user_agent) " +
        "values ($1, $2, now() + make_interval(secs => $3), " +
        "case when $4 ~ '^[0-9a-fA-F.:]{2,45}$' then $4::inet end, nullif(left($5, 512), ''))",
        [pg.arg_text(account_id), pg.arg_bytes(n.token_hash), pg.arg_int(n.ttl_seconds), pg.arg_text(n.ip), pg.arg_text(n.user_agent)], d);
}

gc struct VerifyTx {
    s: Store,
    v: service.VerifyEmail
}

fn verify_tx(c: pg.Conn, t: VerifyTx) -> result[service.Verified, str] {
    let d = pg_deadline(t.s);
    let none_account: opt[domain.Account] = none;
    let none_grant = ledger_store.no_grant();
    let cr = use_code(c, t.v.code, d);
    guard let outcome = cr else let e = err_of(cr) {
        return err(e);
    }
    if outcome.check != service.CodeCheck.Matched {
        return ok(service.Verified { check: outcome.check, attempts_left: outcome.attempts_left, account: none_account, grant: none_grant });
    }
    let id = t.v.code.account_id;
    let up = exec(c,
        "update accounts set status = 'ACTIVE', email_verified_at = coalesce(email_verified_at, now()) " +
        "where id = $1 and status in ('UNVERIFIED', 'ACTIVE')",
        [pg.arg_text(id)], d);
    guard let _u = up else let e = err_of(up) {
        return err(e);
    }
    let gr = ledger_store.grant_current_season(c, id, d);
    guard let grant = gr else let e = err_of(gr) {
        return err("season grant: " + e.detail);
    }
    let sr = insert_session(c, id, t.v.session, d);
    guard let _s = sr else let e = err_of(sr) {
        return err(e);
    }
    let dr = exec(c, "delete from signup_tokens where account_id = $1", [pg.arg_text(id)], d);
    guard let _d = dr else let e = err_of(dr) {
        return err(e);
    }
    let ar = read_account(c, id, d);
    guard let account = ar else let e = err_of(ar) {
        return err(e);
    }
    return ok(service.Verified { check: outcome.check, attempts_left: outcome.attempts_left, account: some(account), grant: grant });
}

fn st_verify_email(s: Store, v: service.VerifyEmail) -> result[service.Verified, service.StoreFail] {
    let r = zokor.transaction(s.pg, VerifyTx { s: s, v: v }, verify_tx, pg_deadline(s));
    guard let out = r else let e = err_of(r) {
        return err(store_fail(e));
    }
    return ok(out);
}

fn upsert_password(c: pg.Conn, id: str, h: str, algo: str, params: str, d: until) -> result[int, str] {
    return exec(c,
        "insert into password_credentials (account_id, hash, algo, params) values ($1, $2, $3, $4) " +
        "on conflict (account_id) do update set hash = excluded.hash, algo = excluded.algo, " +
        "params = excluded.params, updated_at = now()",
        [pg.arg_text(id), pg.arg_text(h), pg.arg_text(algo), pg.arg_text(params)], d);
}

fn revoke_where(c: pg.Conn, id: str, keep: bytes, d: until) -> result[[bytes], str] {
    let r: result[[TokenHashRow], str] = zokor.conn_query_all(c,
        "update sessions set revoked_at = now() where account_id = $1 and revoked_at is null and token_hash <> $2 " +
        "returning token_hash",
        [pg.arg_text(id), pg.arg_bytes(keep)], d);
    guard let rows = r else let e = err_of(r) {
        return err(e);
    }
    let out: [bytes] = [];
    for row in rows {
        push(out, row.token_hash);
    }
    return ok(out);
}

gc struct ResetTx {
    s: Store,
    r: service.ResetPassword
}

fn reset_tx(c: pg.Conn, t: ResetTx) -> result[service.ResetDone, str] {
    let d = pg_deadline(t.s);
    let none_revoked: [bytes] = [];
    let cr = use_code(c, t.r.code, d);
    guard let outcome = cr else let e = err_of(cr) {
        return err(e);
    }
    if outcome.check != service.CodeCheck.Matched {
        return ok(service.ResetDone { check: outcome.check, attempts_left: outcome.attempts_left, revoked: none_revoked });
    }
    let id = t.r.code.account_id;
    let pw = upsert_password(c, id, t.r.password_hash, t.r.password_algo, t.r.password_params, d);
    guard let _p = pw else let e = err_of(pw) {
        return err(e);
    }
    let rr = revoke_where(c, id, b"", d);
    guard let revoked = rr else let e = err_of(rr) {
        return err(e);
    }
    return ok(service.ResetDone { check: outcome.check, attempts_left: outcome.attempts_left, revoked: revoked });
}

fn st_reset_password(s: Store, r: service.ResetPassword) -> result[service.ResetDone, service.StoreFail] {
    let out = zokor.transaction(s.pg, ResetTx { s: s, r: r }, reset_tx, pg_deadline(s));
    guard let done = out else let e = err_of(out) {
        return err(store_fail(e));
    }
    return ok(done);
}

fn st_find_login(s: Store, email: str) -> result[opt[service.LoginRow], service.StoreFail] {
    let r: result[opt[service.LoginRow], str] = zokor.query_one(s.pg,
        "select a.id::text as account_id, a.username::text as username, a.email::text as email, a.status, " +
        "p.hash as password_hash from accounts a left join password_credentials p on p.account_id = a.id " +
        "where a.email = $1 and a.kind = 'USER'",
        [pg.arg_text(email)], pg_deadline(s));
    guard let found = r else let e = err_of(r) {
        return err(unavailable(e));
    }
    return ok(found);
}

fn st_set_password_hash(s: Store, id: str, h: str, algo: str, params: str) -> result[bool, service.StoreFail] {
    let r = pg.pool_query(s.pg,
        "update password_credentials set hash = $2, algo = $3, params = $4, updated_at = now() where account_id = $1",
        [pg.arg_text(id), pg.arg_text(h), pg.arg_text(algo), pg.arg_text(params)], pg_deadline(s));
    guard let _r = r else let e = err_of(r) {
        return err(unavailable(e));
    }
    return ok(true);
}

gc struct SessionTx {
    s: Store,
    account_id: str,
    n: service.NewSession
}

fn session_tx(c: pg.Conn, t: SessionTx) -> result[int, str] {
    return insert_session(c, t.account_id, t.n, pg_deadline(t.s));
}

fn st_create_session(s: Store, account_id: str, n: service.NewSession) -> result[bool, service.StoreFail] {
    let r = zokor.transaction(s.pg, SessionTx { s: s, account_id: account_id, n: n }, session_tx, pg_deadline(s));
    guard let _r = r else let e = err_of(r) {
        return err(store_fail(e));
    }
    return ok(true);
}

fn st_session_lookup(s: Store, h: bytes) -> result[opt[service.SessionRow], service.StoreFail] {
    let r: result[opt[service.SessionRow], str] = zokor.query_one(s.pg,
        "select s.id::text as session_id, s.account_id::text as account_id, a.status, s.expires_at " +
        "from sessions s join accounts a on a.id = s.account_id " +
        "where s.token_hash = $1 and s.revoked_at is null and s.expires_at > now()",
        [pg.arg_bytes(h)], pg_deadline(s));
    guard let found = r else let e = err_of(r) {
        return err(unavailable(e));
    }
    return ok(found);
}

fn st_revoke_session(s: Store, h: bytes) -> result[bool, service.StoreFail] {
    let r = pg.pool_query(s.pg, "update sessions set revoked_at = now() where token_hash = $1 and revoked_at is null",
                          [pg.arg_bytes(h)], pg_deadline(s));
    guard let _r = r else let e = err_of(r) {
        return err(unavailable(e));
    }
    return ok(true);
}

gc struct RevokeTx {
    s: Store,
    id: str,
    keep: bytes
}

fn revoke_tx(c: pg.Conn, t: RevokeTx) -> result[[bytes], str] {
    return revoke_where(c, t.id, t.keep, pg_deadline(t.s));
}

fn st_revoke_others(s: Store, id: str, keep: bytes) -> result[[bytes], service.StoreFail] {
    let r = zokor.transaction(s.pg, RevokeTx { s: s, id: id, keep: keep }, revoke_tx, pg_deadline(s));
    guard let out = r else let e = err_of(r) {
        return err(store_fail(e));
    }
    return ok(out);
}

fn st_touch_session(s: Store, h: bytes) -> result[bool, service.StoreFail] {
    let r = pg.pool_query(s.pg, "update sessions set last_seen_at = now() where token_hash = $1",
                          [pg.arg_bytes(h)], pg_deadline(s));
    guard let _r = r else let e = err_of(r) {
        return err(unavailable(e));
    }
    return ok(true);
}

fn st_password_hash_of(s: Store, id: str) -> result[opt[str], service.StoreFail] {
    let r: result[opt[HashRow], str] = zokor.query_one(s.pg,
        "select hash from password_credentials where account_id = $1", [pg.arg_text(id)], pg_deadline(s));
    guard let found = r else let e = err_of(r) {
        return err(unavailable(e));
    }
    let none_hash: opt[str] = none;
    guard let row = found else {
        return ok(none_hash);
    }
    return ok(some(row.hash));
}

gc struct PasswordTx {
    s: Store,
    id: str,
    hash: str,
    algo: str,
    params: str,
    keep: bytes
}

fn password_tx(c: pg.Conn, t: PasswordTx) -> result[[bytes], str] {
    let d = pg_deadline(t.s);
    let pw = upsert_password(c, t.id, t.hash, t.algo, t.params, d);
    guard let _p = pw else let e = err_of(pw) {
        return err(e);
    }
    return revoke_where(c, t.id, t.keep, d);
}

fn st_change_password(s: Store, id: str, h: str, algo: str, params: str, keep: bytes) -> result[[bytes], service.StoreFail] {
    let r = zokor.transaction(s.pg, PasswordTx { s: s, id: id, hash: h, algo: algo, params: params, keep: keep },
                              password_tx, pg_deadline(s));
    guard let out = r else let e = err_of(r) {
        return err(store_fail(e));
    }
    return ok(out);
}

gc struct HasRow {
    has_password: bool
}

gc struct AccountTx {
    s: Store,
    id: str
}

fn unlink_tx(c: pg.Conn, t: AccountTx) -> result[bool, str] {
    let d = pg_deadline(t.s);
    let r: result[[HasRow], str] = zokor.conn_query_all(c,
        "select exists (select 1 from password_credentials where account_id = a.id) as has_password " +
        "from accounts a where a.id = $1 for update",
        [pg.arg_text(t.id)], d);
    guard let rows = r else let e = err_of(r) {
        return err(e);
    }
    if len(rows) == 0 {
        return err("fault:not_found");
    }
    if !domain.can_unlink_google(rows[0].has_password) {
        return err("fault:last_method");
    }
    let del_r = exec(c, "delete from auth_identities where account_id = $1 and provider = 'google'", [pg.arg_text(t.id)], d);
    guard let _x = del_r else let e = err_of(del_r) {
        return err(e);
    }
    return ok(true);
}

fn st_unlink_google(s: Store, id: str) -> result[bool, service.StoreFail] {
    let r = zokor.transaction(s.pg, AccountTx { s: s, id: id }, unlink_tx, pg_deadline(s));
    guard let _ok = r else let e = err_of(r) {
        return err(store_fail(e));
    }
    return ok(true);
}

fn delete_tx(c: pg.Conn, t: AccountTx) -> result[[bytes], str] {
    let d = pg_deadline(t.s);
    let up = exec(c, "update accounts set status = 'DELETED', deleted_at = coalesce(deleted_at, now()) where id = $1",
                  [pg.arg_text(t.id)], d);
    guard let _u = up else let e = err_of(up) {
        return err(e);
    }
    return revoke_where(c, t.id, b"", d);
}

fn st_delete_account(s: Store, id: str) -> result[[bytes], service.StoreFail] {
    let r = zokor.transaction(s.pg, AccountTx { s: s, id: id }, delete_tx, pg_deadline(s));
    guard let out = r else let e = err_of(r) {
        return err(store_fail(e));
    }
    return ok(out);
}

fn one_id(s: Store, sql: str, v: str) -> result[opt[str], service.StoreFail] {
    let r: result[opt[IdRow], str] = zokor.query_one(s.pg, sql, [pg.arg_text(v)], pg_deadline(s));
    guard let found = r else let e = err_of(r) {
        return err(unavailable(e));
    }
    let none_id: opt[str] = none;
    guard let row = found else {
        return ok(none_id);
    }
    return ok(some(row.id));
}

fn st_identity_owner(s: Store, sub: str) -> result[opt[str], service.StoreFail] {
    return one_id(s, "select account_id::text as id from auth_identities where provider = 'google' and subject = $1", sub);
}

fn st_email_owner(s: Store, email: str) -> result[opt[str], service.StoreFail] {
    return one_id(s, "select id::text as id from accounts where email = $1", email);
}

gc struct GoogleTx {
    s: Store,
    g: service.GoogleSignup
}

fn google_tx(c: pg.Conn, t: GoogleTx) -> result[service.Created, str] {
    let d = pg_deadline(t.s);
    let g = t.g;
    let steps = [
        exec(c, "insert into accounts (id, username, email, status, kind, email_verified_at) " +
                "values ($1, $2, $3, 'ACTIVE', 'USER', now())",
             [pg.arg_text(g.account_id), pg.arg_text(g.username), pg.arg_text(g.email)], d),
        exec(c, "insert into auth_identities (provider, subject, account_id, email_at_link) values ('google', $1, $2, $3)",
             [pg.arg_text(g.subject), pg.arg_text(g.account_id), pg.arg_text(g.email)], d)
    ];
    for st in steps {
        guard let _ok = st else let e = err_of(st) {
            return err(e);
        }
    }
    let gr = ledger_store.grant_current_season(c, g.account_id, d);
    guard let grant = gr else let e = err_of(gr) {
        return err("season grant: " + e.detail);
    }
    let sr = insert_session(c, g.account_id, g.session, d);
    guard let _s = sr else let e = err_of(sr) {
        return err(e);
    }
    let ar = read_account(c, g.account_id, d);
    guard let account = ar else let e = err_of(ar) {
        return err(e);
    }
    return ok(service.Created { account: account, grant: grant });
}

fn st_create_google_account(s: Store, g: service.GoogleSignup) -> result[service.Created, service.StoreFail] {
    let r = zokor.transaction(s.pg, GoogleTx { s: s, g: g }, google_tx, pg_deadline(s));
    guard let out = r else let e = err_of(r) {
        return err(store_fail(e));
    }
    return ok(out);
}

fn st_link_google(s: Store, id: str, sub: str, email: str) -> result[bool, service.StoreFail] {
    let r = pg.pool_query(s.pg,
        "insert into auth_identities (provider, subject, account_id, email_at_link) values ('google', $1, $2, $3)",
        [pg.arg_text(sub), pg.arg_text(id), pg.arg_text(email)], pg_deadline(s));
    guard let _r = r else let e = err_of(r) {
        return err(store_fail(e));
    }
    return ok(true);
}

// One statement for the whole batch: the events travel as one jsonb array.
fn st_insert_audit(s: Store, events: [service.AuditEvent]) -> result[int, str] {
    let r = pg.pool_query(s.pg,
        "insert into audit_events (actor_id, action, target_type, target_id, ip_address, user_agent, detail) " +
        "select nullif(e->>'actor_id', '')::uuid, e->>'action', 'ACCOUNT', nullif(e->>'actor_id', ''), " +
        "case when (e->>'ip') ~ '^[0-9a-fA-F.:]{2,45}$' then (e->>'ip')::inet end, " +
        "nullif(left(e->>'user_agent', 512), ''), coalesce((e->>'detail_json')::jsonb, '{}'::jsonb) " +
        "from jsonb_array_elements($1::jsonb) as e",
        [pg.arg_text(json.encode(events))], pg_deadline(s));
    guard let _r = r else let e = err_of(r) {
        return err(e);
    }
    return ok(len(events));
}

fn st_claim_outbox(s: Store, id: str, limit: int, lease: int) -> result[[service.OutboxItem], str] {
    return zokor.query_all(s.pg,
        "update auth_outbox set next_attempt_at = now() + make_interval(secs => $3), attempts = attempts + 1 " +
        "where id in (select id from auth_outbox where sent_at is null and next_attempt_at <= now() " +
        "and ($1 = '' or id::text = $1) order by next_attempt_at limit $2 for update skip locked) " +
        "returning id::text as id, kind, payload::text as payload, attempts",
        [pg.arg_text(id), pg.arg_int(limit), pg.arg_int(lease)], pg_deadline(s));
}

// The sealed code goes with the send: a delivered row keeps no payload.
fn st_outbox_sent(s: Store, id: str) -> result[bool, str] {
    let r = pg.pool_query(s.pg,
        "update auth_outbox set sent_at = now(), payload = '{}'::jsonb, last_error = null where id = $1",
        [pg.arg_text(id)], pg_deadline(s));
    guard let _r = r else let e = err_of(r) {
        return err(e);
    }
    return ok(true);
}

fn st_outbox_retry(s: Store, id: str, why: str, delay: int) -> result[bool, str] {
    let r = pg.pool_query(s.pg,
        "update auth_outbox set next_attempt_at = now() + make_interval(secs => $3), last_error = left($2, 500) where id = $1",
        [pg.arg_text(id), pg.arg_text(why), pg.arg_int(delay)], pg_deadline(s));
    guard let _r = r else let e = err_of(r) {
        return err(e);
    }
    return ok(true);
}

fn st_sweep_expired(s: Store) -> result[int, str] {
    let none_args: [pg.Arg] = [];
    for sql in [
        "delete from otp_codes where expires_at < now() - interval '1 day'",
        "delete from signup_tokens where expires_at < now()",
        "delete from sessions where expires_at < now() - interval '7 days' or revoked_at < now() - interval '7 days'",
        "delete from otp_sends where sent_at < now() - interval '1 day'",
        "delete from auth_outbox where sent_at < now() - interval '7 days'"
    ] {
        let r = pg.pool_query(s.pg, sql, none_args, pg_deadline(s));
        guard let _r = r else let e = err_of(r) {
            return err(e);
        }
    }
    return ok(0);
}

gc struct RoleRow {
    role: str
}

fn st_roles_of(s: Store, id: str) -> result[[str], service.StoreFail] {
    let r: result[[RoleRow], str] = zokor.query_all(s.pg, "select role from account_roles where account_id = $1::uuid",
                                                   [pg.arg_text(id)], pg_deadline(s));
    guard let rows = r else let e = err_of(r) {
        return err(unavailable(e));
    }
    let out: [str] = [];
    for row in rows {
        push(out, row.role);
    }
    return ok(out);
}

fn st_grant_role(s: Store, id: str, role: str) -> result[bool, service.StoreFail] {
    let r: result[[IdRow], str] = zokor.query_all(s.pg,
        "insert into account_roles (account_id, role) select a.id, $2 from accounts a where a.id = $1::uuid " +
        "on conflict do nothing returning account_id::text as id", [pg.arg_text(id), pg.arg_text(role)], pg_deadline(s));
    guard let rows = r else let e = err_of(r) {
        return err(unavailable(e));
    }
    return ok(len(rows) == 1);
}

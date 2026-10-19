import "crypto";
import "encoding";
import "pg";
import "proc";
import "redis";
import "strings";
import "time";
import "zokor";
import "../service" as service;

fn long_deadline() -> until {
    return until_of(time.mono() + 30000000000);
}

gc struct Live {
    pool: pg.Pool,
    cache: opt[redis.Pool]
}

fn live() -> opt[Live] {
    let none_here: opt[Live] = none;
    let url = proc.getenv("TEST_DATABASE_URL") ?? "";
    let rurl = proc.getenv("TEST_REDIS_URL") ?? "";
    if len(url) == 0 || len(rurl) == 0 {
        println("skip accounts store tests (TEST_DATABASE_URL and TEST_REDIS_URL are not both set)");
        return none_here;
    }
    let m: map[str]str = {};
    m["DATABASE_URL"] = url;
    m["DB_POOL_SIZE"] = "20";
    m["REDIS_URL"] = rurl;
    let cfg = zokor.config_from_values(m);
    let opened = zokor.pg_from_config(cfg);
    guard let pool = opened else let e = err_of(opened) { panic(e); }
    let ms = zokor.load_migrations("migrations", zokor.migration_limits());
    guard let loaded = ms else let e = err_of(ms) { panic(e); }
    let applied = zokor.migrate(pool, loaded, long_deadline());
    guard let _n = applied else let e = err_of(applied) { panic(e); }
    let empty: [pg.Arg] = [];
    let s = pg.pool_query(pool,
        "insert into seasons (ordinal, starts_at, ends_at, status) " +
        "select (select coalesce(max(ordinal), 0) + 1 from seasons), now() - interval '1 day', " +
        "now() + interval '13 days', 'ACTIVE' " +
        "where not exists (select 1 from seasons where status = 'ACTIVE' and starts_at <= now() and ends_at > now())",
        empty, long_deadline());
    guard let _s = s else let e = err_of(s) { panic(e); }
    let rr = zokor.redis_from_config(cfg);
    guard let cache = rr else let e = err_of(rr) { panic(e); }
    flush(cache);
    return some(Live { pool: pool, cache: some(cache) });
}

// The test Redis is ours alone: start every test without the previous
// run's rate-limit counters and holds.
fn flush(pool: redis.Pool) {
    let d = until_of(time.mono() + 2000000000);
    let cr = redis.acquire(pool, d);
    guard let conn = cr else let e = err_of(cr) { panic(e); }
    let r = redis.do(conn, [to_bytes("FLUSHDB")], d);
    redis.release(pool, conn);
    guard let _ok = r else let e = err_of(r) { panic(e); }
}

fn uuid() -> str {
    let rb = crypto.rand(16);
    guard let b = rb else { panic("rand"); }
    let h = encoding.hex_encode(b);
    return strings.slice(h, 0, 8) + "-" + strings.slice(h, 8, 12) + "-4" + strings.slice(h, 13, 16) +
           "-a" + strings.slice(h, 17, 20) + "-" + strings.slice(h, 20, 32);
}

fn suffix() -> str {
    let rb = crypto.rand(4);
    guard let b = rb else { panic("rand"); }
    return encoding.hex_encode(b);
}

fn stub_hash(p: str) -> result[str, str] {
    return ok("stub$" + p);
}

fn stub_verify(p: str, enc: str) -> result[bool, str] {
    return ok(enc == "stub$" + p);
}

gc struct Inbox {
    lock: mutex,
    codes: map[str]str,
    fail: bool,
    sent: int
}

fn inbox_send(i: Inbox, m: service.Mail) -> result[bool, str] {
    if i.fail {
        return err("provider down");
    }
    mutex_lock(i.lock);
    i.codes[m.to] = m.code;
    i.sent += 1;
    mutex_unlock(i.lock);
    return ok(true);
}

fn new_inbox() -> Inbox {
    let codes: map[str]str = {};
    return Inbox { lock: make_mutex(), codes: codes, fail: false, sent: 0 };
}

fn code_for(i: Inbox, email: str) -> str {
    for n in 0..500 {
        mutex_lock(i.lock);
        let has_it = has(i.codes, email);
        let c = "";
        if has_it {
            c = i.codes[email];
        }
        mutex_unlock(i.lock);
        if has_it {
            return c;
        }
        time.sleep(2000000);
    }
    panic("no code delivered to " + email);
}

fn config() -> service.AuthConfig {
    return service.AuthConfig {
        otp_secret: to_bytes("integration-otp-secret-0123456789abcdef"),
        reserved: ["say", "admin"],
        grant_amount: 1000,
        session_ttl_seconds: 2592000,
        signup_ttl_seconds: 1800,
        hold_seconds: 600,
        pending_seconds: 900,
        oauth_state_seconds: 600,
        google_client_id: "client-1",
        google_redirect_uri: "http://localhost/cb",
        google_auth_url: "https://accounts.google.com/o/oauth2/v2/auth",
        dummy_hash: "stub$dummy"
    };
}

fn auth_on(l: Live, with_redis: bool) -> service.Auth[Store] {
    let cache = l.cache;
    if !with_redis {
        let none_cache: opt[redis.Pool] = none;
        cache = none_cache;
    }
    let st = new_store(l.pool, cache,
        GoogleEndpoints { client_id: "client-1", client_secret: "s", token_url: "http://127.0.0.1:9/token", jwks_url: "http://127.0.0.1:9/jwks" },
        Timeouts { pg_ns: 10000000000, redis_ns: 200000000, google_ns: 1000000000 });
    return service.new_auth(auth_store(st), config(), service.new_hasher(4, 256, stub_hash, stub_verify), uuid);
}

fn mail(i: Inbox) -> service.Mailer[Inbox] {
    return service.Mailer[Inbox] { context: i, send: inbox_send };
}

fn meta_from(ip: str) -> service.Meta {
    return service.Meta { ip: ip, user_agent: "integration" };
}

gc struct IntRow {
    n: int
}

fn count(pool: pg.Pool, sql: str, arg: str) -> int {
    let r: result[opt[IntRow], str] = zokor.query_one(pool, sql, [pg.arg_text(arg)], long_deadline());
    guard let found = r else let e = err_of(r) { panic(e); }
    guard let row = found else { return -1; }
    return row.n;
}

fn sign_up(a: service.Auth[Store], i: Inbox, name: str, ip: str) -> service.SignupStarted {
    let hr = service.hold_username(a, name, ip);
    guard let hold = hr else let f = err_of(hr) { panic("hold " + inspect(f.why)); }
    let r = service.signup(a, mail(i), name, hold.hold_id, name + "@it.say", "correct horse", meta_from(ip));
    guard let s = r else let fs = err_of(r) { panic("signup " + inspect(fs[0].why) + " " + fs[0].detail); }
    return s;
}

fn test_should_run_the_password_path_to_exactly_one_thousand_sedis() {
    guard let l = live() else { return; }
    let a = auth_on(l, true);
    let inbox = new_inbox();
    let name = "pp" + suffix();
    let check = service.check_username(a, name, "10.9.0.1");
    guard let c = check else { panic("check"); }
    assert(c.available, inspect(c.reason));
    let s = sign_up(a, inbox, name, "10.9.0.1");
    let vr = service.verify_signup(a, s.signup_token, code_for(inbox, name + "@it.say"), meta_from("10.9.0.1"));
    guard let v = vr else let f = err_of(vr) { panic("verify " + inspect(f.why) + " " + f.detail); }
    guard let grant = v.grant else { panic("no grant"); }
    assert(grant.amount == 1000 && grant.season_ordinal >= 1);
    let id = v.account.id;
    assert(count(l.pool, "select free_units as n from wallets where account_id = $1", id) == 1000);
    assert(count(l.pool, "select count(*)::bigint as n from issuance_grants where account_id = $1", id) == 1);
    let again = service.check_username(a, name, "10.9.0.1");
    guard let c2 = again else { panic("check"); }
    assert(!c2.available && c2.reason == "USERNAME_TAKEN" && len(c2.suggestions) == 3, inspect(c2.suggestions));
}

gc struct Race {
    lock: mutex,
    ok: int,
    taken: int,
    other: [str]
}

fn race_signup(a: service.Auth[Store], i: Inbox, name: str, n: int, r: Race, done: chan[int]) {
    let res = service.signup(a, mail(i), name, "none", name + to_str(n) + "@it.say", "correct horse", meta_from("10.8." + to_str(n / 200) + "." + to_str(n % 200)));
    mutex_lock(r.lock);
    if let _s = res {
        r.ok += 1;
    } else let fs = err_of(res) {
        if fs[0].why == service.Why.UsernameTaken {
            r.taken += 1;
        } else {
            push(r.other, inspect(fs[0].why) + " " + fs[0].detail);
        }
    }
    mutex_unlock(r.lock);
    chan_send(done, 1);
}

// No Redis, so no hold: fifty requests race straight into the unique
// constraint, which is the guarantee the spec rests on.
fn test_should_let_exactly_one_of_fifty_parallel_signups_have_a_username() {
    guard let l = live() else { return; }
    let a = auth_on(l, false);
    let inbox = new_inbox();
    let name = "rc" + suffix();
    let r = Race { lock: make_mutex(), ok: 0, taken: 0, other: [] };
    let done: chan[int] = make_chan(50);
    for n in 0..50 {
        spawn race_signup(a, inbox, name, n, r, done);
    }
    for n in 0..50 {
        let _d = chan_recv(done);
    }
    assert(r.ok == 1, "ok=" + to_str(r.ok) + " taken=" + to_str(r.taken) + " " + inspect(r.other));
    assert(r.taken == 49, inspect(r.other));
}

fn race_verify(a: service.Auth[Store], token: str, code: str, r: Race, done: chan[int]) {
    let res = service.verify_signup(a, token, code, meta_from("10.7.0.1"));
    mutex_lock(r.lock);
    if let _v = res {
        r.ok += 1;
    } else let f = err_of(res) {
        push(r.other, inspect(f.why));
    }
    mutex_unlock(r.lock);
    chan_send(done, 1);
}

fn test_should_grant_once_for_twenty_parallel_correct_verifies() {
    guard let l = live() else { return; }
    let a = auth_on(l, false);
    let inbox = new_inbox();
    let name = "vr" + suffix();
    let s = sign_up(a, inbox, name, "10.7.0.1");
    let code = code_for(inbox, name + "@it.say");
    let r = Race { lock: make_mutex(), ok: 0, taken: 0, other: [] };
    let done: chan[int] = make_chan(20);
    for n in 0..20 {
        spawn race_verify(a, s.signup_token, code, r, done);
    }
    for n in 0..20 {
        let _d = chan_recv(done);
    }
    assert(r.ok == 1, "ok=" + to_str(r.ok) + " " + inspect(r.other));
    let id = one_account(l.pool, name);
    assert(count(l.pool, "select count(*)::bigint as n from issuance_grants where account_id = $1", id) == 1);
    assert(count(l.pool, "select count(*)::bigint as n from ledger_transactions t join issuance_grants g on g.journal_id = t.id where g.account_id = $1", id) == 1);
    assert(count(l.pool, "select free_units as n from wallets where account_id = $1", id) == 1000);
}

gc struct IdRow2 {
    id: str
}

fn one_account(pool: pg.Pool, name: str) -> str {
    let r: result[opt[IdRow2], str] = zokor.query_one(pool, "select id::text as id from accounts where username = $1",
                                                      [pg.arg_text(name)], long_deadline());
    guard let found = r else let e = err_of(r) { panic(e); }
    guard let row = found else { panic("no account " + name); }
    return row.id;
}

fn test_should_lock_after_five_of_fifty_parallel_wrong_guesses() {
    guard let l = live() else { return; }
    let a = auth_on(l, false);
    let inbox = new_inbox();
    let name = "wg" + suffix();
    let s = sign_up(a, inbox, name, "10.6.0.1");
    let code = code_for(inbox, name + "@it.say");
    let wrong = "000000";
    if code == wrong { wrong = "999999"; }
    let r = Race { lock: make_mutex(), ok: 0, taken: 0, other: [] };
    let done: chan[int] = make_chan(50);
    for n in 0..50 {
        spawn race_verify(a, s.signup_token, wrong, r, done);
    }
    for n in 0..50 {
        let _d = chan_recv(done);
    }
    assert(r.ok == 0);
    let id = one_account(l.pool, name);
    assert(count(l.pool, "select attempts::bigint as n from otp_codes where account_id = $1 and consumed_at is null", id) == 5);
    let late = service.verify_signup(a, s.signup_token, code, meta_from("10.6.0.2"));
    guard let _v = late else let f = err_of(late) {
        assert(f.why == service.Why.OtpLocked, inspect(f.why));
        return;
    }
    panic("correct code accepted after lock-out");
}

fn signed_in(a: service.Auth[Store], i: Inbox, name: str) -> str {
    let s = sign_up(a, i, name, "10.5.0.1");
    let vr = service.verify_signup(a, s.signup_token, code_for(i, name + "@it.say"), meta_from("10.5.0.1"));
    guard let v = vr else let f = err_of(vr) { panic("verify " + inspect(f.why)); }
    return v.session_token;
}

fn session_of(a: service.Auth[Store], token: str) -> opt[service.Session] {
    let r = service.authenticate(a, token);
    guard let found = r else let f = err_of(r) { panic("authenticate " + inspect(f.why) + " " + f.detail); }
    return found;
}

fn test_should_reject_a_revoked_session_with_redis_on_and_off() {
    guard let l = live() else { return; }
    let with_redis = auth_on(l, true);
    let without = auth_on(l, false);
    let inbox = new_inbox();
    let token = signed_in(with_redis, inbox, "sr" + suffix());
    guard let s = session_of(with_redis, token) else { panic("not signed in"); }
    guard let _cached = session_of(with_redis, token) else { panic("cache miss failed"); }
    let _o = service.logout(with_redis, s, meta_from("10.5.0.1"));
    if let _x = session_of(with_redis, token) { panic("revoked session accepted with redis"); }
    if let _x = session_of(without, token) { panic("revoked session accepted without redis"); }

    let token2 = signed_in(without, inbox, "sn" + suffix());
    guard let s2 = session_of(without, token2) else { panic("no session without redis"); }
    let _o2 = service.logout(without, s2, meta_from("10.5.0.1"));
    if let _x = session_of(without, token2) { panic("revoked session accepted without redis"); }
}

fn test_should_log_in_and_log_out_everywhere_else() {
    guard let l = live() else { return; }
    let a = auth_on(l, true);
    let inbox = new_inbox();
    let name = "lo" + suffix();
    let first = signed_in(a, inbox, name);
    let lr = service.login(a, name + "@it.say", "correct horse", meta_from("10.4.0.1"));
    guard let second = lr else let f = err_of(lr) { panic("login " + inspect(f.why)); }
    guard let s = session_of(a, second.session_token) else { panic("second session"); }
    let n = service.logout_others(a, s, meta_from("10.4.0.1"));
    assert((n ?? 0) == 1, inspect(n));
    if let _x = session_of(a, first) { panic("first session survived logout-others"); }
    guard let _keep = session_of(a, second.session_token) else { panic("current session revoked"); }
}

fn test_should_reset_the_password_and_revoke_every_session() {
    guard let l = live() else { return; }
    let a = auth_on(l, true);
    let inbox = new_inbox();
    let name = "rs" + suffix();
    let email = name + "@it.say";
    let token = signed_in(a, inbox, name);
    mutex_lock(inbox.lock);
    del(inbox.codes, email);
    mutex_unlock(inbox.lock);
    let empty: [pg.Arg] = [];
    let _c = pg.pool_query(l.pool, "update otp_sends set sent_at = sent_at - interval '2 minutes' where email = $1",
                           [pg.arg_text(email)], long_deadline());
    let _f = service.forgot_password(a, mail(inbox), email, meta_from("10.3.0.1"));
    let rr = service.reset_password(a, email, code_for(inbox, email), "brand new horse", meta_from("10.3.0.1"));
    guard let revoked = rr else let f = err_of(rr) { panic("reset " + inspect(f.why)); }
    assert(revoked == 1, inspect(revoked));
    if let _x = session_of(a, token) { panic("session survived reset"); }
    let lr = service.login(a, email, "brand new horse", meta_from("10.3.0.1"));
    guard let _ok = lr else { panic("new password refused"); }
}

fn test_should_answer_unverified_login_with_a_signup_token() {
    guard let l = live() else { return; }
    let a = auth_on(l, true);
    let inbox = new_inbox();
    let name = "uv" + suffix();
    let _s = sign_up(a, inbox, name, "10.2.0.1");
    let lr = service.login(a, name + "@it.say", "correct horse", meta_from("10.2.0.1"));
    guard let _x = lr else let f = err_of(lr) {
        assert(f.why == service.Why.EmailNotVerified, inspect(f.why));
        let pr = service.resend(a, mail(inbox), f.signup_token, "", "verify_email", meta_from("10.2.0.1"));
        guard let _q = pr else let rf = err_of(pr) {
            assert(rf.why == service.Why.RateLimited && rf.retry_after > 0, inspect(rf.why));
            return;
        }
        panic("resend inside the 60 s cooldown");
    }
    panic("unverified login accepted");
}

fn test_should_keep_the_code_owed_while_the_provider_is_down() {
    guard let l = live() else { return; }
    let a = auth_on(l, true);
    let inbox = new_inbox();
    inbox.fail = true;
    let name = "ob" + suffix();
    let email = name + "@it.say";
    let s = sign_up(a, inbox, name, "10.1.0.1");
    time.sleep(100000000);
    assert(count(l.pool, "select count(*)::bigint as n from auth_outbox where sent_at is null and payload->>'to' = $1", email) == 1);
    let _r = pg.pool_query(l.pool, "update auth_outbox set next_attempt_at = now() where payload->>'to' = $1",
                           [pg.arg_text(email)], long_deadline());
    inbox.fail = false;
    let _n = service.deliver(a, mail(inbox), "");
    let code = code_for(inbox, email);
    assert(count(l.pool, "select count(*)::bigint as n from auth_outbox where payload->>'to' = $1", email) == 0,
           "delivered row still carries its payload");
    let vr = service.verify_signup(a, s.signup_token, code, meta_from("10.1.0.1"));
    guard let _v = vr else let f = err_of(vr) { panic("verify after recovery " + inspect(f.why)); }
}

fn test_should_rate_limit_through_redis() {
    guard let l = live() else { return; }
    let a = auth_on(l, true);
    let ip = "10.200." + to_str(len(suffix())) + "." + to_str(time.wall() % 250);
    let limited = 0;
    for i in 0..7 {
        let r = service.signup(a, mail(new_inbox()), "a", "h", "bad", "x", meta_from(ip));
        if let _s = r {
        } else let fs = err_of(r) {
            if fs[0].why == service.Why.RateLimited {
                limited += 1;
            }
        }
    }
    assert(limited == 2, "limited " + to_str(limited));
}

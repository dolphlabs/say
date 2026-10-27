import "crypto";
import "encoding";
import "http";
import "proc";
import "redis";
import "strings";
import "time";
import "timez";
import "zokor";
import "../../platform/app" as app;
import "../../platform/cache" as cache;
import "../../platform/config" as config;
import "../../platform/db" as db;
import "../../platform/email" as email;
import "../../platform/web" as web;
import "../../ledger/store" as ledger_store;

gc struct Rig {
    r: zokor.Router[app.App],
    mail: email.Email
}

fn d10() -> until {
    return until_of(time.mono() + 10000000000);
}

fn rig() -> opt[Rig] {
    let none_rig: opt[Rig] = none;
    let url = proc.getenv("TEST_DATABASE_URL") ?? "";
    let rurl = proc.getenv("TEST_REDIS_URL") ?? "";
    if len(url) == 0 || len(rurl) == 0 {
        println("skip accounts http tests (TEST_DATABASE_URL and TEST_REDIS_URL are not both set)");
        return none_rig;
    }
    let m: map[str]str = {};
    m["PORT"] = "8080";
    m["DATABASE_URL"] = url;
    m["REDIS_URL"] = rurl;
    m["OTP_SECRET"] = "http-test-otp-secret-0123456789abcdef";
    m["HASH_WORKERS"] = "2";
    let cfg = zokor.config_from_values(m);
    let settings = config.settings_from(cfg);
    let dr = db.open(cfg);
    guard let d = dr else let e = err_of(dr) { panic(e); }
    let ms = zokor.load_migrations("migrations", zokor.migration_limits());
    guard let loaded = ms else let e = err_of(ms) { panic(e); }
    let applied = zokor.migrate(d.pool, loaded, d10());
    guard let _n = applied else let e = err_of(applied) { panic(e); }
    prepare_ledger(d);
    let cr = cache.open(cfg);
    guard let c = cr else let e = err_of(cr) { panic(e); }
    if let pool = c.pool {
        let conn_r = redis.acquire(pool, d10());
        guard let conn = conn_r else { panic("redis"); }
        let _f = redis.do(conn, [to_bytes("FLUSHDB")], d10());
        redis.release(pool, conn);
    }
    let mail = email.in_memory();
    let ar = app.for_tests(settings, d, c, mail);
    guard let state = ar else let e = err_of(ar) { panic(e); }
    let r = zokor.new_router(state);
    web.register_common(r.errors);
    mount(r);
    return some(Rig { r: r, mail: mail });
}

fn tag() -> str {
    let rb = crypto.rand(4);
    guard let b = rb else { panic("rand"); }
    return encoding.hex_encode(b);
}

fn post(r: zokor.Router[app.App], path: str, body: str, cookie: str) -> http.Response {
    let req = zokor.request(zokor.Method.POST, path).json_body(body);
    if len(cookie) > 0 {
        req = req.header("cookie", cookie);
    }
    return r.serve(req.build());
}

fn get(r: zokor.Router[app.App], path: str, cookie: str) -> http.Response {
    let req = zokor.get_request(path);
    if len(cookie) > 0 {
        req = req.header("cookie", cookie);
    }
    return r.serve(req.build());
}

fn delete(r: zokor.Router[app.App], path: str, cookie: str) -> http.Response {
    return r.serve(zokor.request(zokor.Method.DELETE, path).header("cookie", cookie).build());
}

fn code_sent_to(mail: email.Email, to: str, nth: int) -> str {
    for i in 0..500 {
        let seen = 0;
        for m in email.sent_messages(mail) {
            if m.to[0] == to {
                seen += 1;
                if seen == nth {
                    let at = strings.find(m.text, "is:\n\n");
                    return strings.slice(m.text, at + 5, at + 11);
                }
            }
        }
        time.sleep(2000000);
    }
    panic("no code for " + to);
}

fn session_cookie_of(resp: http.Response) -> str {
    let sc = zokor.resp_header(resp, "set-cookie");
    let semi = strings.find(sc, ";");
    if semi < 0 {
        return sc;
    }
    return strings.slice(sc, 0, semi);
}

fn error_code(resp: http.Response) -> str {
    return zokor.resp_json(resp).path("error.code").str_or("");
}

gc struct Person {
    name: str,
    email: str,
    cookie: str
}

fn verified_person(g: Rig) -> Person {
    let name = "h" + tag();
    let addr = name + "@http.say";
    let hold = post(g.r, "/v1/auth/username/hold", "{\"username\":\"" + name + "\"}", "");
    assert(zokor.resp_status(hold) == 200, zokor.resp_text(hold));
    let hold_id = zokor.resp_json(hold).get("hold_id").str_or("");
    let su = post(g.r, "/v1/auth/signup", "{\"username\":\"" + name + "\",\"hold_id\":\"" + hold_id +
                  "\",\"email\":\"" + addr + "\",\"password\":\"correct horse\"}", "");
    assert(zokor.resp_status(su) == 201, zokor.resp_text(su));
    let token = zokor.resp_json(su).get("signup_token").str_or("");
    let v = post(g.r, "/v1/auth/otp/verify", "{\"signup_token\":\"" + token + "\",\"code\":\"" +
                 code_sent_to(g.mail, addr, 1) + "\"}", "");
    assert(zokor.resp_status(v) == 200, zokor.resp_text(v));
    return Person { name: name, email: addr, cookie: session_cookie_of(v) };
}

fn test_should_run_check_hold_signup_verify_me_logout_over_http() {
    guard let g = rig() else { return; }
    let name = "h" + tag();
    let addr = name + "@http.say";
    let check = get(g.r, "/v1/auth/username/" + strings.to_upper(name), "");
    assert(zokor.resp_status(check) == 200 && zokor.resp_json(check).get("available").bool_or(false), zokor.resp_text(check));
    let hold = post(g.r, "/v1/auth/username/hold", "{\"username\":\"" + name + "\"}", "");
    let hold_id = zokor.resp_json(hold).get("hold_id").str_or("");
    assert(len(hold_id) == 32, zokor.resp_text(hold));
    let su = post(g.r, "/v1/auth/signup", "{\"username\":\"" + name + "\",\"hold_id\":\"" + hold_id +
                  "\",\"email\":\"" + strings.to_upper(addr) + "\",\"password\":\"correct horse\"}", "");
    assert(zokor.resp_status(su) == 201, zokor.resp_text(su));
    let sj = zokor.resp_json(su);
    assert(strings.has_suffix(sj.get("email_masked").str_or(""), "@http.say"));
    assert(len(sj.get("resend_available_at").str_or("")) > 0);
    let v = post(g.r, "/v1/auth/otp/verify", "{\"signup_token\":\"" + sj.get("signup_token").str_or("") +
                 "\",\"code\":\"" + code_sent_to(g.mail, addr, 1) + "\"}", "");
    assert(zokor.resp_status(v) == 200, zokor.resp_text(v));
    let vj = zokor.resp_json(v);
    assert(vj.path("grant.amount").int_or(0) == 1000, zokor.resp_text(v));
    assert(vj.path("grant.season_ordinal").int_or(0) >= 1);
    assert(len(vj.path("grant.season_ends_at").str_or("")) > 0);
    let sc = zokor.resp_header(v, "set-cookie");
    for flag in ["say_session=", "HttpOnly", "Secure", "SameSite=Lax", "Path=/"] {
        assert(strings.contains(sc, flag), "cookie lacks " + flag + ": " + sc);
    }
    let cookie = session_cookie_of(v);
    let me = get(g.r, "/v1/me", cookie);
    assert(zokor.resp_status(me) == 200, zokor.resp_text(me));
    let mj = zokor.resp_json(me);
    assert(mj.get("username").str_or("") == name);
    assert(mj.get("email").str_or("") == addr);
    assert(mj.get("email_verified").bool_or(false) && mj.get("has_password").bool_or(false));
    assert(!mj.get("google_linked").bool_or(true));
    assert(len(mj.get("username_changeable_at").str_or("")) > 0);
    let out = post(g.r, "/v1/auth/logout", "{}", cookie);
    assert(zokor.resp_status(out) == 204);
    assert(strings.contains(zokor.resp_header(out, "set-cookie"), "Max-Age=0"));
    let after = get(g.r, "/v1/me", cookie);
    assert(zokor.resp_status(after) == 401 && error_code(after) == "UNAUTHENTICATED", zokor.resp_text(after));
}

fn test_should_answer_every_login_failure_with_invalid_credentials() {
    guard let g = rig() else { return; }
    let p = verified_person(g);
    for body in ["{\"email\":\"" + p.email + "\",\"password\":\"wrong horse\"}",
                 "{\"email\":\"nobody-" + tag() + "@http.say\",\"password\":\"correct horse\"}"] {
        let r = post(g.r, "/v1/auth/login", body, "");
        assert(zokor.resp_status(r) == 401 && error_code(r) == "INVALID_CREDENTIALS", zokor.resp_text(r));
        assert(len(zokor.resp_json(r).path("error.message").str_or("")) > 0);
    }
    let ok_r = post(g.r, "/v1/auth/login", "{\"email\":\"" + p.email + "\",\"password\":\"correct horse\"}", "");
    assert(zokor.resp_status(ok_r) == 200, zokor.resp_text(ok_r));
    assert(zokor.resp_json(ok_r).path("user.username").str_or("") == p.name);
}

fn test_should_send_unverified_logins_back_to_the_code_screen() {
    guard let g = rig() else { return; }
    let name = "u" + tag();
    let hold = post(g.r, "/v1/auth/username/hold", "{\"username\":\"" + name + "\"}", "");
    let hold_id = zokor.resp_json(hold).get("hold_id").str_or("");
    let su = post(g.r, "/v1/auth/signup", "{\"username\":\"" + name + "\",\"hold_id\":\"" + hold_id +
                  "\",\"email\":\"" + name + "@http.say\",\"password\":\"correct horse\"}", "");
    assert(zokor.resp_status(su) == 201);
    let r = post(g.r, "/v1/auth/login", "{\"email\":\"" + name + "@http.say\",\"password\":\"correct horse\"}", "");
    assert(zokor.resp_status(r) == 403 && error_code(r) == "EMAIL_NOT_VERIFIED", zokor.resp_text(r));
    assert(len(zokor.resp_json(r).path("error.signup_token").str_or("")) > 20, zokor.resp_text(r));
}

fn test_should_report_attempts_left_and_retry_after() {
    guard let g = rig() else { return; }
    let name = "a" + tag();
    let addr = name + "@http.say";
    let hold = post(g.r, "/v1/auth/username/hold", "{\"username\":\"" + name + "\"}", "");
    let hold_id = zokor.resp_json(hold).get("hold_id").str_or("");
    let su = post(g.r, "/v1/auth/signup", "{\"username\":\"" + name + "\",\"hold_id\":\"" + hold_id +
                  "\",\"email\":\"" + addr + "\",\"password\":\"correct horse\"}", "");
    let token = zokor.resp_json(su).get("signup_token").str_or("");
    let code = code_sent_to(g.mail, addr, 1);
    let wrong = "000000";
    if code == wrong { wrong = "999999"; }
    let bad = post(g.r, "/v1/auth/otp/verify", "{\"signup_token\":\"" + token + "\",\"code\":\"" + wrong + "\"}", "");
    assert(zokor.resp_status(bad) == 400 && error_code(bad) == "OTP_INVALID", zokor.resp_text(bad));
    assert(zokor.resp_json(bad).path("error.attempts_left").int_or(-1) == 4, zokor.resp_text(bad));
    let again = post(g.r, "/v1/auth/otp/resend", "{\"signup_token\":\"" + token + "\",\"purpose\":\"verify_email\"}", "");
    assert(zokor.resp_status(again) == 429 && error_code(again) == "RATE_LIMITED", zokor.resp_text(again));
    let retry = zokor.resp_json(again).path("error.retry_after").int_or(0);
    assert(retry > 0 && retry <= 60, zokor.resp_text(again));
    assert(zokor.resp_header(again, "retry-after") == to_str(retry));
}

fn test_should_report_every_signup_problem_under_the_first_code() {
    guard let g = rig() else { return; }
    let r = post(g.r, "/v1/auth/signup", "{\"username\":\"A!\",\"hold_id\":\"x\",\"email\":\"nope\",\"password\":\"short\"}", "");
    assert(zokor.resp_status(r) == 422 && error_code(r) == "USERNAME_INVALID", zokor.resp_text(r));
    assert(zokor.resp_json(r).path("error.fields").size() == 3, zokor.resp_text(r));
}

fn test_should_accept_forgot_password_for_any_email() {
    guard let g = rig() else { return; }
    let r = post(g.r, "/v1/auth/password/forgot", "{\"email\":\"ghost-" + tag() + "@http.say\"}", "");
    assert(zokor.resp_status(r) == 202, zokor.resp_text(r));
}

fn test_should_accept_a_bearer_token_for_mobile_clients() {
    guard let g = rig() else { return; }
    let p = verified_person(g);
    let token = strings.slice(p.cookie, len("say_session="), len(p.cookie));
    let me = g.r.serve(zokor.get_request("/v1/me").bearer(token).build());
    assert(zokor.resp_status(me) == 200, zokor.resp_text(me));
}

fn test_should_guard_me_and_logout_others() {
    guard let g = rig() else { return; }
    for path in ["/v1/me"] {
        let r = get(g.r, path, "");
        assert(zokor.resp_status(r) == 401 && error_code(r) == "UNAUTHENTICATED", zokor.resp_text(r));
    }
    let lo = post(g.r, "/v1/auth/logout-others", "{}", "say_session=forged");
    assert(zokor.resp_status(lo) == 401, zokor.resp_text(lo));
}

fn test_should_change_password_and_end_other_sessions() {
    guard let g = rig() else { return; }
    let p = verified_person(g);
    let other = post(g.r, "/v1/auth/login", "{\"email\":\"" + p.email + "\",\"password\":\"correct horse\"}", "");
    let other_cookie = session_cookie_of(other);
    let wrong = post(g.r, "/v1/me/password", "{\"current_password\":\"nope nope\",\"new_password\":\"fresh horse 2\"}", p.cookie);
    assert(zokor.resp_status(wrong) == 401 && error_code(wrong) == "INVALID_CREDENTIALS", zokor.resp_text(wrong));
    let ch = post(g.r, "/v1/me/password", "{\"current_password\":\"correct horse\",\"new_password\":\"fresh horse 2\"}", p.cookie);
    assert(zokor.resp_status(ch) == 204, zokor.resp_text(ch));
    assert(zokor.resp_status(get(g.r, "/v1/me", p.cookie)) == 200);
    assert(zokor.resp_status(get(g.r, "/v1/me", other_cookie)) == 401);
}

fn test_should_log_out_others_and_keep_this_session() {
    guard let g = rig() else { return; }
    let p = verified_person(g);
    let other = post(g.r, "/v1/auth/login", "{\"email\":\"" + p.email + "\",\"password\":\"correct horse\"}", "");
    let other_cookie = session_cookie_of(other);
    let lo = post(g.r, "/v1/auth/logout-others", "{}", p.cookie);
    assert(zokor.resp_status(lo) == 204, zokor.resp_text(lo));
    assert(zokor.resp_status(get(g.r, "/v1/me", p.cookie)) == 200);
    assert(zokor.resp_status(get(g.r, "/v1/me", other_cookie)) == 401);
}

fn test_should_soft_delete_and_sign_out() {
    guard let g = rig() else { return; }
    let p = verified_person(g);
    let unlink = delete(g.r, "/v1/me/google", p.cookie);
    assert(zokor.resp_status(unlink) == 204, zokor.resp_text(unlink));
    let del_r = delete(g.r, "/v1/me", p.cookie);
    assert(zokor.resp_status(del_r) == 202, zokor.resp_text(del_r));
    assert(zokor.resp_status(get(g.r, "/v1/me", p.cookie)) == 401);
    let login = post(g.r, "/v1/auth/login", "{\"email\":\"" + p.email + "\",\"password\":\"correct horse\"}", "");
    assert(zokor.resp_status(login) == 401 && error_code(login) == "INVALID_CREDENTIALS");
}

fn test_should_redirect_to_google_with_pkce() {
    guard let g = rig() else { return; }
    let r = get(g.r, "/v1/auth/google/start?intent=signup", "");
    assert(zokor.resp_status(r) == 502 || zokor.resp_status(r) == 302, zokor.resp_text(r));
    let cb = get(g.r, "/v1/auth/google/callback?state=unknown&code=x", "");
    assert(zokor.resp_status(cb) == 302);
    assert(strings.contains(zokor.resp_header(cb, "location"), "/login?error=PENDING_EXPIRED"), zokor.resp_header(cb, "location"));
}

// Seasons from SEASON_ANCHOR's default and an approved S 1,000 policy, as
// the scheduler and the operators would leave them, so verification grants.
fn prepare_ledger(d: db.Db) {
    let none_redis: opt[redis.Pool] = none;
    let st = ledger_store.ledger_store(ledger_store.new_postgres(d.pool, none_redis, 10000000000, 50000000));
    let ar = timez.parse_rfc3339("2026-10-11T23:00:00Z");
    guard let anchor = ar else { panic("anchor"); }
    let tick = st.tick;
    let r = tick(st.context, timez.now(), anchor);
    guard let _rep = r else let e = err_of(r) { panic("season tick: " + e); }
    let pr = db.run(d,
        "with op as (insert into accounts (username, email, status, email_verified_at) " +
        "select 'policyop', 'policyop@test.say', 'ACTIVE', now() " +
        "where not exists (select 1 from issuance_policies where status = 'APPROVED') " +
        "on conflict (username) do update set status = 'ACTIVE' returning id) " +
        "insert into issuance_policies (amount, season_cap, status, proposed_by, approved_at) " +
        "select 1000, 1000000000000, 'APPROVED', id, now() from op",
        d10());
    guard let _p = pr else let e = err_of(pr) { panic("policy: " + e); }
}

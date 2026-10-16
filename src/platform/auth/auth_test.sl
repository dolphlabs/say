import "http";
import "zokor";
import "../app" as app;
import "../config" as config;

fn whoami(c: zokor.Ctx[app.App]) -> http.Response {
    return zokor.text(200, c.local("tenant_id"));
}

fn guarded() -> zokor.Router[app.App] {
    let m: map[str]str = {};
    m["PORT"] = "8080";
    m["API_KEYS"] = "acme:acme-key-0123456789abcdef012345";
    let r = zokor.new_router(app.for_tests(config.settings_from(zokor.config_from_values(m))));
    r.before(require_tenant);
    r.get("/whoami", whoami);
    return r;
}

fn test_a_known_key_names_its_tenant() {
    let r = guarded().serve(zokor.get_request("/whoami")
                            .header("x-api-key", "acme-key-0123456789abcdef012345").build());
    assert(zokor.resp_status(r) == 200 && zokor.resp_text(r) == "acme", zokor.resp_text(r));
}

fn test_a_missing_or_wrong_key_is_401() {
    let none_given = guarded().serve(zokor.get_request("/whoami").build());
    assert(zokor.resp_status(none_given) == 401);
    let wrong = guarded().serve(zokor.get_request("/whoami").header("x-api-key", "nope").build());
    assert(zokor.resp_status(wrong) == 401);
}

fn me(c: zokor.Ctx[app.App]) -> http.Response {
    let body = c.local("account_id") + ":" + c.local("username") + ":" + c.local("email");
    return zokor.text(200, body);
}

fn session_router() -> zokor.Router[app.App] {
    let m: map[str]str = {};
    m["PORT"] = "8080";
    m["COOKIE_KEYS"] = "0123456789012345678901234567890123456789";
    m["JWT_SECRETS"] = "0123456789012345678901234567890123456789";
    let r = zokor.new_router(app.for_tests(config.settings_from(zokor.config_from_values(m))));
    r.before(require_session);
    r.get("/me", me);
    return r;
}

fn test_session_cookie_lifecycle() {
    let r = session_router();
    let s = r.state.settings;

    let c_res = issue_session_cookie("acc_123", "user@say.exchange", "say_user", "USER", s.jwt_auth, s.cookie_keys);
    guard let c = c_res else let e = err_of(c_res) { panic(e); }
    assert(c.name == "say_session");
    assert(c.path == "/");
    assert(c.http_only);
    assert(c.max_age == 604800);

    // Call /me with valid cookie
    let cookie_hdr = c.name + "=" + c.value;
    let ok_resp = r.serve(zokor.get_request("/me").header("cookie", cookie_hdr).build());
    assert(zokor.resp_status(ok_resp) == 200, zokor.resp_text(ok_resp));
    assert(zokor.resp_text(ok_resp) == "acc_123:say_user:user@say.exchange");

    // Missing cookie is 401
    let unauth = r.serve(zokor.get_request("/me").build());
    assert(zokor.resp_status(unauth) == 401);

    let tampered = r.serve(zokor.get_request("/me").header("cookie", "say_session=tampered.fake_signature").build());
    assert(zokor.resp_status(tampered) == 401);

    let verified_raw = zokor.verify_signed("say_session", c.value, s.cookie_keys);
    guard let token_str = verified_raw else { panic("signed cookie verification failed"); }
    let claims_res: result[SessionClaims, str] = jwt.verify(token_str, s.jwt_auth.keys[0]);
    guard let claims = claims_res else { panic("jwt verify failed"); }
    let _rev = app.revoke_session(r.state, claims.jti, 3600);

    let revoked_resp = r.serve(zokor.get_request("/me").header("cookie", cookie_hdr).build());
    assert(zokor.resp_status(revoked_resp) == 401);

    let bearer_resp = r.serve(zokor.get_request("/me").header("authorization", "Bearer " + token_str).build());
    assert(zokor.resp_status(bearer_resp) == 401);
}

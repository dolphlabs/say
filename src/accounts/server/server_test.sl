import "http";
import "strings";
import "zokor";
import "../../platform/app" as app;
import "../../platform/config" as config;

fn router_under_test() -> zokor.Router[app.App] {
    let m: map[str]str = {};
    m["PORT"] = "8080";
    m["COOKIE_KEYS"] = "0123456789012345678901234567890123456789";
    m["JWT_SECRETS"] = "0123456789012345678901234567890123456789";
    let cfg = zokor.config_from_values(m);
    let r = zokor.new_router(app.for_tests(config.settings_from(cfg)));
    mount(r);
    return r;
}

fn test_check_username_availability_endpoint() {
    let r = router_under_test();

    // Check available username (<= 10 characters)
    let ok_resp = r.serve(zokor.get_request("/v1/accounts/check-username?username=cool_user").build());
    assert(zokor.resp_status(ok_resp) == 200, zokor.resp_text(ok_resp));
    assert(zokor.resp_json(ok_resp).get("available").bool_or(false));

    // Too long username (> 10 characters)
    let long_resp = r.serve(zokor.get_request("/v1/accounts/check-username?username=fresh_trader").build());
    assert(zokor.resp_status(long_resp) == 422, zokor.resp_text(long_resp));

    // Too short username (< 3 characters)
    let bad_resp = r.serve(zokor.get_request("/v1/accounts/check-username?username=ab").build());
    assert(zokor.resp_status(bad_resp) == 422, zokor.resp_text(bad_resp));

    // Empty username
    let empty_resp = r.serve(zokor.get_request("/v1/accounts/check-username").build());
    assert(zokor.resp_status(empty_resp) == 422, zokor.resp_text(empty_resp));
}

fn test_register_account_flow() {
    let r = router_under_test();
    let body = "{\"username\":\"trader_joe\",\"email\":\"joe@say.exchange\",\"password\":\"ValidPass123!\",\"phone_number\":\"+2349012345678\"}";
    let req = zokor.request(zokor.Method.POST, "/v1/accounts")
        .header("user-agent", "Mozilla/5.0")
        .header("x-forwarded-for", "192.168.1.100")
        .json_body(body)
        .build();
    let made = r.serve(req);
    assert(zokor.resp_status(made) == 201, zokor.resp_text(made));
    let j = zokor.resp_json(made);
    let id = j.get("id").str_or("");
    assert(j.get("username").str_or("") == "trader_joe");
    assert(j.get("email").str_or("") == "joe@say.exchange");
    assert(j.get("phone_number").str_or("") == "+2349012345678");
    assert(!j.get("email_verified").bool_or(true));
    assert(!j.get("is_verified").bool_or(true));
    // Ensure password_hash is not returned in response
    assert(!j.has_key("password_hash"));

    // Query account by id
    let show = r.serve(zokor.get_request("/v1/accounts/" + id).build());
    assert(zokor.resp_status(show) == 200, zokor.resp_text(show));
    assert(zokor.resp_json(show).get("username").str_or("") == "trader_joe");
    assert(!zokor.resp_json(show).get("email_verified").bool_or(true));

    // Username now taken
    let check_taken = r.serve(zokor.get_request("/v1/accounts/check-username?username=trader_joe").build());
    assert(zokor.resp_status(check_taken) == 409, zokor.resp_text(check_taken));

    // Duplicate email fails
    let dup_email_body = "{\"username\":\"other_user\",\"email\":\"joe@say.exchange\",\"password\":\"ValidPass123!\"}";
    let dup_resp = r.serve(zokor.request(zokor.Method.POST, "/v1/accounts").json_body(dup_email_body).build());
    assert(zokor.resp_status(dup_resp) == 409, zokor.resp_text(dup_resp));
}

fn test_verify_email_endpoint_flow() {
    let r = router_under_test();
    let reg_body = "{\"username\":\"verify_usr\",\"email\":\"verify@say.exchange\",\"password\":\"ValidPass123!\"}";
    let reg_req = zokor.request(zokor.Method.POST, "/v1/accounts").json_body(reg_body).build();
    let made = r.serve(reg_req);
    assert(zokor.resp_status(made) == 201, zokor.resp_text(made));
    let acc_id = zokor.resp_json(made).get("id").str_or("");

    // Setup a known code in cache to verify directly
    let _sc = app.save_verification_code(r.state, "8CHARCOD", "verify@say.exchange", 3600);

    // Mismatched code fails
    let bad_code_body = "{\"email\":\"verify@say.exchange\",\"code\":\"WRONGCOD\"}";
    let bad_code_resp = r.serve(zokor.request(zokor.Method.POST, "/v1/accounts/verify-email").json_body(bad_code_body).build());
    assert(zokor.resp_status(bad_code_resp) == 400, zokor.resp_text(bad_code_resp));

    // Mismatched email fails
    let bad_email_body = "{\"email\":\"wrong@say.exchange\",\"code\":\"8CHARCOD\"}";
    let bad_email_resp = r.serve(zokor.request(zokor.Method.POST, "/v1/accounts/verify-email").json_body(bad_email_body).build());
    assert(zokor.resp_status(bad_email_resp) == 400, zokor.resp_text(bad_email_resp));

    // Valid code & matching email succeeds
    let ok_body = "{\"email\":\"verify@say.exchange\",\"code\":\"8CHARCOD\"}";
    let ok_resp = r.serve(zokor.request(zokor.Method.POST, "/v1/accounts/verify-email").json_body(ok_body).build());
    assert(zokor.resp_status(ok_resp) == 200, zokor.resp_text(ok_resp));
    let verified_json = zokor.resp_json(ok_resp);
    assert(verified_json.get("email_verified").bool_or(false));
    assert(verified_json.get("is_verified").bool_or(false));

    // Verify session cookie was set
    let set_cookie = zokor.resp_header(ok_resp, "set-cookie");
    assert(strings.find(set_cookie, "say_session=") >= 0, "expected say_session cookie in " + set_cookie);
    assert(strings.find(set_cookie, "HttpOnly") >= 0, "cookie must be HttpOnly");
    assert(strings.find(set_cookie, "SameSite=Lax") >= 0, "cookie must be SameSite=Lax");
    assert(strings.find(set_cookie, "Max-Age=604800") >= 0, "cookie must have 7-day max-age");

    // Replay with consumed code fails
    let replay_resp = r.serve(zokor.request(zokor.Method.POST, "/v1/accounts/verify-email").json_body(ok_body).build());
    assert(zokor.resp_status(replay_resp) == 400, zokor.resp_text(replay_resp));

    // Verify account record is now verified when fetched
    let show = r.serve(zokor.get_request("/v1/accounts/" + acc_id).build());
    assert(zokor.resp_status(show) == 200, zokor.resp_text(show));
    assert(zokor.resp_json(show).get("email_verified").bool_or(false));
}

fn test_register_with_weak_password_fails() {
    let r = router_under_test();
    let body = "{\"username\":\"weak_user\",\"email\":\"weak@say.exchange\",\"password\":\"weak\"}";
    let resp = r.serve(zokor.request(zokor.Method.POST, "/v1/accounts").json_body(body).build());
    assert(zokor.resp_status(resp) == 422, zokor.resp_text(resp));
}

fn test_listing_is_paged_and_bounded() {
    let r = router_under_test();
    for t in ["a", "b", "c"] {
        let b = "{\"username\":\"user_" + t + "\",\"email\":\"" + t + "@say.exchange\",\"password\":\"ValidPass123!\"}";
        let _m = r.serve(zokor.request(zokor.Method.POST, "/v1/accounts").json_body(b).build());
    }
    let page = r.serve(zokor.get_request("/v1/accounts?offset=1&limit=1").build());
    let data = zokor.resp_json(page).get("data");
    assert(data.size() == 1, zokor.resp_text(page));
    let too_many = r.serve(zokor.get_request("/v1/accounts?limit=1000").build());
    assert(zokor.resp_status(too_many) == 422);
}

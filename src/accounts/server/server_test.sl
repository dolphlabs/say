import "http";
import "zokor";
import "../../platform/app" as app;
import "../../platform/config" as config;

// The routes through the real router pipeline -- auth, decoding, the use
// cases, the memory store -- without a socket.

fn key_a() -> str { return "acme-0123456789abcdef0123456789"; }
fn key_b() -> str { return "globex-0123456789abcdef01234567"; }

fn router_under_test() -> zokor.Router[app.App] {
    let m: map[str]str = {};
    m["PORT"] = "8080";
    m["API_KEYS"] = "acme:" + key_a() + ",globex:" + key_b();
    let cfg = zokor.config_from_values(m);
    let r = zokor.new_router(app.for_tests(config.settings_from(cfg)));
    mount(r);
    return r;
}

fn post_account(r: zokor.Router[app.App], key: str, body: str) -> http.Response {
    return r.serve(zokor.request(zokor.Method.POST, "/accounts").header("x-api-key", key)
                   .json_body(body).build());
}

fn test_one_account_round_trips() {
    let r = router_under_test();
    let made = post_account(r, key_a(), "{\"email\":\"trader@say.exchange\",\"auth_provider\":\"LOCAL\"}");
    assert(zokor.resp_status(made) == 201, zokor.resp_text(made));
    let id = zokor.resp_json(made).get("id").str_or("");
    let mine = r.serve(zokor.get_request("/accounts/" + id).header("x-api-key", key_a()).build());
    assert(zokor.resp_status(mine) == 200, zokor.resp_text(mine));
    assert(zokor.resp_json(mine).get("email").str_or("") == "trader@say.exchange");
}

fn test_no_key_is_401_and_reaches_nothing() {
    let r = router_under_test();
    let denied = r.serve(zokor.get_request("/accounts").build());
    assert(zokor.resp_status(denied) == 401, zokor.resp_text(denied));
}

fn test_listing_is_paged_and_bounded() {
    let r = router_under_test();
    for t in ["a", "b", "c"] {
        let _m = post_account(r, key_a(), "{\"email\":\"" + t + "@say.exchange\",\"auth_provider\":\"LOCAL\"}");
    }
    let page = r.serve(zokor.get_request("/accounts?offset=1&limit=1").header("x-api-key", key_a()).build());
    let data = zokor.resp_json(page).get("data");
    assert(data.size() == 1, zokor.resp_text(page));
    let too_many = r.serve(zokor.get_request("/accounts?limit=1000").header("x-api-key", key_a()).build());
    assert(zokor.resp_status(too_many) == 422);
}

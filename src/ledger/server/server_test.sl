import "proc";
import "time";
import "zokor";
import "../../platform/app" as app;
import "../../platform/cache" as cache;
import "../../platform/config" as config;
import "../../platform/db" as db;
import "../../platform/email" as email;
import "../../platform/web" as web;

fn router() -> opt[zokor.Router[app.App]] {
    let none_r: opt[zokor.Router[app.App]] = none;
    let url = proc.getenv("TEST_DATABASE_URL") ?? "";
    if len(url) == 0 {
        println("skip ledger http tests (TEST_DATABASE_URL is not set)");
        return none_r;
    }
    let m: map[str]str = {};
    m["PORT"] = "8080";
    m["DATABASE_URL"] = url;
    m["OTP_SECRET"] = "ledger-test-otp-secret-0123456789abcdef";
    let cfg = zokor.config_from_values(m);
    let dr = db.open(cfg);
    guard let d = dr else let e = err_of(dr) { panic(e); }
    let deadline = until_of(time.mono() + 10000000000);
    let ms = zokor.load_migrations("migrations", zokor.migration_limits());
    guard let loaded = ms else let e = err_of(ms) { panic(e); }
    let applied = zokor.migrate(d.pool, loaded, deadline);
    guard let _n = applied else let e = err_of(applied) { panic(e); }
    let s = db.run(d,
        "insert into seasons (ordinal, starts_at, ends_at, status) " +
        "select (select coalesce(max(ordinal), 0) + 1 from seasons), now() - interval '1 day', " +
        "now() + interval '13 days', 'ACTIVE' " +
        "where not exists (select 1 from seasons where status = 'ACTIVE' and starts_at <= now() and ends_at > now())",
        deadline);
    guard let _s = s else let e = err_of(s) { panic(e); }
    let ar = app.for_tests(config.settings_from(cfg), d, cache.in_memory(), email.in_memory());
    guard let state = ar else let e = err_of(ar) { panic(e); }
    let r = zokor.new_router(state);
    web.register_common(r.errors);
    mount(r);
    return some(r);
}

fn test_should_show_the_current_season_publicly() {
    guard let r = router() else { return; }
    let resp = r.serve(zokor.get_request("/v1/seasons/current").build());
    assert(zokor.resp_status(resp) == 200, zokor.resp_text(resp));
    let j = zokor.resp_json(resp);
    assert(j.path("season.ordinal").int_or(0) >= 1, zokor.resp_text(resp));
    assert(j.path("season.status").str_or("") == "ACTIVE");
    assert(len(j.path("season.ends_at").str_or("")) > 0);
}

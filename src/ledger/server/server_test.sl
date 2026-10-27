import "crypto";
import "encoding";
import "http";
import "proc";
import "redis";
import "time";
import "timez";
import "zokor";
import "../../platform/app" as app;
import "../../platform/cache" as cache;
import "../../platform/config" as config;
import "../../platform/db" as db;
import "../../platform/email" as email;
import "../../platform/web" as web;
import "../domain" as domain;
import "../service" as ledger;
import "../store" as ledger_store;

fn test_should_map_ledger_faults_to_api_codes() {
    assert(code_of_fault(domain.Fault.InsufficientFunds) == "INSUFFICIENT_FUNDS");
    assert(code_of_fault(domain.Fault.CapReached) == "ISSUANCE_UNAVAILABLE");
    assert(code_of_fault(domain.Fault.Unbalanced) == "UNAVAILABLE");
}

fn d10() -> until {
    return until_of(time.mono() + 10000000000);
}

gc struct Rig {
    r: zokor.Router[app.App],
    owner: db.Db,
    state: app.App
}

fn open_db(url: str) -> db.Db {
    let m: map[str]str = {};
    m["DATABASE_URL"] = url;
    let r = db.open(zokor.config_from_values(m));
    guard let d = r else let e = err_of(r) { panic(e); }
    return d;
}

fn text(d: db.Db, q: str, args: [str]) -> str {
    let r = db.one_text(d, q, args, d10());
    guard let t = r else let e = err_of(r) { panic(q + ": " + e); }
    return t;
}

// The service as it runs: migrated by the owner, serving as say_api, with
// seasons from the scheduler and an approved policy.
fn rig() -> opt[Rig] {
    let none_rig: opt[Rig] = none;
    let owner_url = proc.getenv("TEST_DATABASE_URL") ?? "";
    let app_url = proc.getenv("TEST_APP_DATABASE_URL") ?? "";
    if len(owner_url) == 0 || len(app_url) == 0 {
        println("skip ledger http tests (TEST_DATABASE_URL / TEST_APP_DATABASE_URL not set)");
        return none_rig;
    }
    let owner = open_db(owner_url);
    let ms = zokor.load_migrations("migrations", zokor.migration_limits());
    guard let loaded = ms else let e = err_of(ms) { panic(e); }
    let applied = zokor.migrate(owner.pool, loaded, d10());
    guard let _n = applied else let e = err_of(applied) { panic(e); }
    let m: map[str]str = {};
    m["PORT"] = "8080";
    m["DATABASE_URL"] = app_url;
    m["OTP_SECRET"] = "ledger-http-otp-secret-0123456789abcdef";
    let cfg = zokor.config_from_values(m);
    let settings = config.settings_from(cfg);
    let dr = db.open(cfg);
    guard let d = dr else let e = err_of(dr) { panic(e); }
    let none_redis: opt[redis.Pool] = none;
    let st = ledger_store.ledger_store(ledger_store.new_postgres(d.pool, none_redis, 10000000000, 50000000));
    let tick = st.tick;
    let tr = tick(st.context, timez.now(), settings.ledger.season_anchor);
    guard let _t = tr else let e = err_of(tr) { panic("tick: " + e); }
    let _p = text(owner,
        "with op as (insert into accounts (username, email, status, email_verified_at) " +
        "select 'policyop', 'policyop@test.say', 'ACTIVE', now() " +
        "where not exists (select 1 from issuance_policies where status = 'APPROVED') " +
        "on conflict (username) do update set status = 'ACTIVE' returning id) " +
        "insert into issuance_policies (amount, season_cap, status, proposed_by, approved_at) " +
        "select 1000, 1000000000000, 'APPROVED', id, now() from op returning id::text as t", []);
    let ar = app.for_tests(settings, d, cache.in_memory(), email.in_memory());
    guard let state = ar else let e = err_of(ar) { panic(e); }
    let r = zokor.new_router(state);
    web.register_common(r.errors);
    mount(r);
    return some(Rig { r: r, owner: owner, state: state });
}

// A verified player with a live session and this season's grant, given
// by the rollover as it would be; returns the cookie header.
fn player(rg: Rig, role: str) -> str {
    let rb = crypto.rand(6);
    guard let b = rb else { panic("rand"); }
    let name = "l" + encoding.hex_encode(b);
    let mail = name + "@test.say";
    let id = text(rg.owner,
        "insert into accounts (username, email, status, email_verified_at) values ($1, $2, 'ACTIVE', now()) returning id::text as t",
        [name, mail]);
    if len(role) > 0 {
        let _r = text(rg.owner, "insert into account_roles (account_id, role) values ($1::uuid, $2) returning role as t", [id, role]);
    }
    let token = "tok-" + name + "-0123456789abcdef0123456789";
    let hash = encoding.hex_encode(crypto.sha256(to_bytes(token)));
    let _s = text(rg.owner, "insert into sessions (account_id, token_hash, expires_at) " +
                            "values ($1::uuid, decode($2, 'hex'), now() + interval '1 hour') returning id::text as t", [id, hash]);
    let season = text(rg.owner,
        "update grant_runs g set finished_at = null, last_account_id = null from seasons s where s.id = g.season_id and s.status = 'ACTIVE' " +
        "returning g.season_id::text as t", []);
    let _g = ledger.run_rollover(rg.state.ledger, season);
    return "say_session=" + token;
}

fn get(rg: Rig, path: str, cookie: str) -> http.Response {
    let req = zokor.get_request(path);
    if len(cookie) > 0 {
        req = req.header("cookie", cookie);
    }
    return rg.r.serve(req.build());
}

fn post(rg: Rig, path: str, body: str, cookie: str) -> http.Response {
    let req = zokor.request(zokor.Method.POST, path).json_body(body);
    if len(cookie) > 0 {
        req = req.header("cookie", cookie);
    }
    return rg.r.serve(req.build());
}

fn test_should_show_the_current_season_with_its_day_and_zone() {
    guard let rg = rig() else { return; }
    let resp = get(rg, "/v1/seasons/current", "");
    assert(zokor.resp_status(resp) == 200, zokor.resp_text(resp));
    let j = zokor.resp_json(resp);
    assert(j.get("ordinal").int_or(0) >= 1);
    assert(j.get("status").str_or("") == "ACTIVE");
    assert(j.get("days_total").int_or(0) == 14);
    assert(j.get("timezone").str_or("") == "Africa/Lagos");
    let day = j.get("day").int_or(0);
    assert(day >= 1 && day <= 14, zokor.resp_text(resp));
    assert(len(j.get("server_time").str_or("")) > 0);
}

fn test_should_show_a_season_by_number_as_provisional_until_final() {
    guard let rg = rig() else { return; }
    let resp = get(rg, "/v1/seasons/1", "");
    assert(zokor.resp_status(resp) == 200, zokor.resp_text(resp));
    let j = zokor.resp_json(resp);
    assert(!j.get("finalized").bool_or(true));
    assert(len(j.get("provisional_reason").str_or("")) > 0);
    assert(zokor.resp_status(get(rg, "/v1/seasons/9999", "")) == 404);
    assert(zokor.resp_status(get(rg, "/v1/seasons/0", "")) == 400);
}

fn test_should_show_the_balance_and_activity_to_the_signed_in_player() {
    guard let rg = rig() else { return; }
    assert(zokor.resp_status(get(rg, "/v1/me/balance", "")) == 401);
    let cookie = player(rg, "");
    let resp = get(rg, "/v1/me/balance?season=current", cookie);
    assert(zokor.resp_status(resp) == 200, zokor.resp_text(resp));
    let j = zokor.resp_json(resp);
    assert(j.get("available").int_or(-1) == 1000, zokor.resp_text(resp));
    assert(j.get("held").int_or(-1) == 0);
    assert(j.get("starting_grant").int_or(0) == 1000);
    assert(j.path("season.status").str_or("") == "ACTIVE");

    let page = get(rg, "/v1/me/ledger?limit=50", cookie);
    assert(zokor.resp_status(page) == 200, zokor.resp_text(page));
    let items = zokor.resp_json(page).get("items");
    assert(items.size() == 1, zokor.resp_text(page));
    assert(items.at(0).get("kind").str_or("") == "SEASON_GRANT");
    assert(items.at(0).get("delta").int_or(0) == 1000);
    assert(items.at(0).get("available_after").int_or(0) == 1000);
    assert(zokor.resp_json(page).get("next_cursor").is_null());

    let sum = get(rg, "/v1/me/summary", cookie);
    assert(zokor.resp_status(sum) == 200, zokor.resp_text(sum));
    assert(zokor.resp_json(sum).path("balance.available").int_or(0) == 1000);
    assert(zokor.resp_json(sum).path("season.days_total").int_or(0) == 14);

    assert(zokor.resp_status(get(rg, "/v1/me/ledger?limit=500", cookie)) == 400);
    assert(zokor.resp_status(get(rg, "/v1/me/ledger?cursor=bm9wZQ", cookie)) == 400);
}

fn test_should_keep_admin_routes_to_operators() {
    guard let rg = rig() else { return; }
    let player_cookie = player(rg, "");
    assert(zokor.resp_status(get(rg, "/v1/admin/reconciliation/latest", player_cookie)) == 403);
    let admin = player(rg, "admin");
    let run = post(rg, "/v1/admin/reconciliation/run", "{}", admin);
    assert(zokor.resp_status(run) == 202, zokor.resp_text(run));
    assert(len(zokor.resp_json(run).get("run_id").str_or("")) == 36);
    let latest = get(rg, "/v1/admin/reconciliation/latest", admin);
    assert(zokor.resp_status(latest) == 200, zokor.resp_text(latest));
    assert(zokor.resp_status(post(rg, "/v1/admin/trading-halt/clear", "{\"reason\":\"checked\"}", admin)) == 403);
    let sup = player(rg, "super_admin");
    let cleared = post(rg, "/v1/admin/trading-halt/clear", "{\"reason\":\"checked the books\"}", sup);
    assert(zokor.resp_status(cleared) == 204, zokor.resp_text(cleared));
}

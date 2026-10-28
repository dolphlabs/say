import "proc";
import "time";
import "zokor";
import "platform/app" as app;
import "platform/config" as config;
import "platform/db" as db;
import "platform/cache" as cache;
import "platform/web" as web;
import "accounts/server" as accounts;
import "ledger/server" as ledger;
import "markets/server" as markets;
import "exchange/server" as exchange;
// zokor:imports

fn db_ready(s: app.App) -> result[int, str] {
    guard let d = s.db else {
        return err("no database");
    }
    return db.ping(d, until_of(time.mono() + 1000000000));
}

fn cache_ready(s: app.App) -> result[int, str] {
    guard let c = s.cache else {
        return err("no cache");
    }
    return cache.ping(c, until_of(time.mono() + 1000000000));
}

let cfg = zokor.load_config();
let settings = config.settings_from(cfg);
let checked = zokor.check(cfg);

guard let _ok = checked else let e = err_of(checked) {
    println(e);
    exit(2);
}

let opened_db = db.open(cfg);
guard let d = opened_db else let e = err_of(opened_db) {
    println("cannot open database: " + e);
    exit(1);
}

let opened_cache = cache.open(cfg);
guard let c = opened_cache else let e = err_of(opened_cache) {
    println("cannot open cache: " + e);
    exit(1);
}

let built = app.build(settings, d, c);
guard let state = built else let e = err_of(built) {
    println("cannot start: " + e);
    exit(1);
}

let args = proc.args();
if len(args) > 1 && args[1] == "admin" {
    exit(app.run_admin(state, args));
}

let r = zokor.new_router(state);
web.register_common(r.errors);
r.health();
r.ready_check("db", db_ready);
r.ready_check("cache", cache_ready);
accounts.mount(r);
ledger.mount(r);
exchange.mount(r);
markets.mount(r);
// zokor:mount
if len(settings.ledger.metrics_token) > 0 {
    r.get("/metrics", app.metrics_route);
}

app.start_workers(state);

let served = zokor.listen_and_serve_with(r, settings.port, settings.server);

guard let _done = served else {
    exit(1);
}

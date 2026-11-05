import "proc";
import "time";
import "zokor";
import "../cache" as cache;
import "../config" as config;
import "../db" as db;
import "../email" as email;
import "../../exchange/service" as exchange;

fn runtime_deadline() -> until { return until_of(time.mono() + 10000000000); }

fn runtime_rig() -> opt[App] {
    let none_app: opt[App] = none;
    let url = proc.getenv("TEST_DATABASE_URL") ?? "";
    let rurl = proc.getenv("TEST_REDIS_URL") ?? "";
    if len(url) == 0 || len(rurl) == 0 {
        println("skip runtime rejoin tests (TEST_DATABASE_URL and TEST_REDIS_URL are not both set)");
        return none_app;
    }
    let m: map[str]str = {};
    m["PORT"] = "8080";
    m["DATABASE_URL"] = url;
    m["REDIS_URL"] = rurl;
    m["OTP_SECRET"] = "runtime-test-otp-secret-0123456789abcdef";
    m["HASH_WORKERS"] = "1";
    let cfg = zokor.config_from_values(m);
    let settings = config.settings_from(cfg);
    let dr = db.open(cfg);
    guard let d = dr else let e = err_of(dr) { panic(e); }
    let ms = zokor.load_migrations("migrations", zokor.migration_limits());
    guard let loaded = ms else let e = err_of(ms) { panic(e); }
    let applied = zokor.migrate(d.pool, loaded, runtime_deadline());
    guard let _n = applied else let e = err_of(applied) { panic(e); }
    let cr = cache.open(cfg);
    guard let c = cr else let e = err_of(cr) { panic(e); }
    let ar = for_tests(settings, d, c, email.in_memory());
    guard let a = ar else let e = err_of(ar) { panic(e); }
    return some(a);
}

fn node_live(a: App, node: str) -> bool {
    let none_ids: [str] = [];
    let none_epochs: [int] = [];
    let beat = exchange.heartbeat(a.heartbeat_ownership, node, a.settings.exchange.lease_seconds, none_ids, none_epochs);
    guard let b = beat else let e = err_of(beat) { panic(e); }
    return b.node_live;
}

fn expire(a: App) {
    mutex_lock(a.runtime.lock);
    a.runtime.live = false;
    mutex_unlock(a.runtime.lock);
}

fn test_should_rejoin_as_a_new_live_node_after_the_old_one_expires() {
    guard let a = runtime_rig() else { return; }
    let first = runtime_node(a);
    assert(node_live(a, first));
    expire(a);
    if let _ok = runtime_ready(a) { panic("an expired runtime reported ready"); }
    let joined = rejoin(a);
    guard let node = joined else let e = err_of(joined) { panic(e); }
    assert(node != first && runtime_node(a) == node);
    assert(node_live(a, node));
    let ready = runtime_ready(a);
    guard let _ready = ready else let e = err_of(ready) { panic(e); }
}

fn finish_market(a: App, id: str) -> int {
    time.sleep(300000000);
    mutex_lock(a.runtime.lock);
    del(a.runtime.active, id);
    mutex_unlock(a.runtime.lock);
    return 0;
}

fn test_should_wait_for_the_old_markets_to_stop_before_rejoining() {
    guard let a = runtime_rig() else { return; }
    let first = runtime_node(a);
    expire(a);
    mutex_lock(a.runtime.lock);
    a.runtime.active["00000000-0000-4000-a000-000000000777"] = true;
    a.runtime.epochs["00000000-0000-4000-a000-000000000777"] = 3;
    mutex_unlock(a.runtime.lock);
    spawn finish_market(a, "00000000-0000-4000-a000-000000000777");
    let started = time.mono();
    let joined = rejoin(a);
    guard let node = joined else let e = err_of(joined) { panic(e); }
    assert(time.mono() - started >= 250000000);
    assert(node != first);
    mutex_lock(a.runtime.lock);
    let cleared = len(a.runtime.active) == 0 && len(a.runtime.epochs) == 0;
    mutex_unlock(a.runtime.lock);
    assert(cleared);
}

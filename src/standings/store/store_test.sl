import "crypto";
import "encoding";
import "pg";
import "proc";
import "strings";
import "time";
import "zokor";
import "../../profiles/store" as profiles;

fn test_store_compilation() {
    // Store type and constructors compile cleanly
    assert(true);
}

gc struct TestDb { base: pg.Pool, owner: pg.Pool, app: pg.Pool, name: str }

fn open_pool(url: str) -> pg.Pool {
    let cfg: map[str]str = {};
    cfg["DATABASE_URL"] = url;
    let opened = zokor.pg_from_config(zokor.config_from_values(cfg));
    guard let pool = opened else let e = err_of(opened) { panic(e); }
    return pool;
}

fn run_sql(pool: pg.Pool, sql: str) {
    let args: [pg.Arg] = [];
    let r = pg.pool_query(pool, sql, args, until_of(time.mono() + 30000000000));
    guard let _ok = r else let e = err_of(r) { panic(e); }
}

fn fresh_db() -> opt[TestDb] {
    let url = proc.getenv("TEST_DATABASE_URL") ?? "";
    let app_url = proc.getenv("TEST_APP_DATABASE_URL") ?? "";
    if len(url) == 0 || len(app_url) == 0 { println("skip standings integration test (test database URLs not set)"); return none; }
    let random = crypto.rand(5);
    guard let random_bytes = random else { panic("random database name unavailable"); }
    let name = "say_standings_" + encoding.hex_encode(random_bytes);
    let base = open_pool(url);
    run_sql(base, "create database " + name);
    let owner = open_pool(strings.replace(url, "/say_test?", "/" + name + "?"));
    let migrations = zokor.load_migrations("migrations", zokor.migration_limits());
    guard let loaded = migrations else let e = err_of(migrations) { panic(e); }
    let applied = zokor.migrate(owner, loaded, until_of(time.mono() + 60000000000));
    guard let _done = applied else let e = err_of(applied) { panic(e); }
    let app = open_pool(strings.replace(app_url, "/say_test?", "/" + name + "?"));
    return some(TestDb { base: base, owner: owner, app: app, name: name });
}

fn close_db(db: TestDb) {
    zokor.pg_close(db.app);
    zokor.pg_close(db.owner);
    run_sql(db.base, "drop database " + db.name + " with (force)");
    zokor.pg_close(db.base);
}

fn test_recompute_counts_cash_open_positions_and_results_for_the_current_season() {
    guard let db = fresh_db() else { return; }
    let p = db.owner;
    run_sql(p, "insert into accounts(id,username,status,kind) values ('00000000-0000-4000-8000-000000000001','kemi.calls','ACTIVE','USER')");
    run_sql(p, "insert into seasons(id,ordinal,starts_at,ends_at,status) values ('00000000-0000-4000-8000-000000000004',2,now() - interval '1 day',now() + interval '13 days','ACTIVE'),('00000000-0000-4000-8000-000000000009',1,now() - interval '30 days',now() - interval '16 days','FINALIZED')");
    run_sql(p, "insert into markets(id,slug,question,status,created_by,tick,redemption_units,season_id) values ('00000000-0000-4000-8000-000000000005','one','Market one?','DRAFT','00000000-0000-4000-8000-000000000001',1,100,'00000000-0000-4000-8000-000000000004'),('00000000-0000-4000-8000-000000000006','two','Market two?','DRAFT','00000000-0000-4000-8000-000000000001',1,100,'00000000-0000-4000-8000-000000000004'),('00000000-0000-4000-8000-000000000007','three','Market three?','DRAFT','00000000-0000-4000-8000-000000000001',1,100,'00000000-0000-4000-8000-000000000004')");
    run_sql(p, "insert into wallets(season_id,owner_kind,owner_id,account_id,asset_key,free_units,held_units) values ('00000000-0000-4000-8000-000000000004','user','00000000-0000-4000-8000-000000000001','00000000-0000-4000-8000-000000000001','SEDI',400,100),('00000000-0000-4000-8000-000000000009','user','00000000-0000-4000-8000-000000000001','00000000-0000-4000-8000-000000000001','SEDI',9000,0)");
    run_sql(p, "insert into positions(account_id,market_id,season_id,outcome,qty,cost_basis) values ('00000000-0000-4000-8000-000000000001','00000000-0000-4000-8000-000000000005','00000000-0000-4000-8000-000000000004','NO',10,300),('00000000-0000-4000-8000-000000000001','00000000-0000-4000-8000-000000000006','00000000-0000-4000-8000-000000000004','YES',0,0),('00000000-0000-4000-8000-000000000001','00000000-0000-4000-8000-000000000007','00000000-0000-4000-8000-000000000004','NO',0,0)");
    run_sql(p, "insert into market_stats(market_id,last_price) values ('00000000-0000-4000-8000-000000000005',60)");
    run_sql(p, "insert into position_results(account_id,market_id,season_id,outcome,qty,cost_basis,paid_out,pnl,result) values ('00000000-0000-4000-8000-000000000001','00000000-0000-4000-8000-000000000006','00000000-0000-4000-8000-000000000004','YES',5,200,500,300,'WON'),('00000000-0000-4000-8000-000000000001','00000000-0000-4000-8000-000000000007','00000000-0000-4000-8000-000000000004','NO',5,150,0,-150,'LOST')");
    let store = new_store(db.app);
    let r = recompute_season_standings(store, time.wall() / 1000000);
    guard let _n = r else let e = err_of(r) { panic(e); }
    let rows = load_standings_rows(store, 2, "profit", 10);
    guard let list = rows else let e = err_of(rows) { panic(e); }
    assert(len(list) == 1);
    assert(list[0].profit == 900, to_str(list[0].profit));
    assert(list[0].calls == 3, to_str(list[0].calls));
    assert(list[0].win_rate == "", list[0].win_rate);
    let pstore = profiles.new_store(db.app);
    let found = profiles.find_user(pstore, "Kemi.Calls");
    guard let user = found else let e = err_of(found) { panic(e); }
    assert(user.found && user.joined_season == "Season 02", user.joined_season);
    assert(strings.has_prefix(user.avatar_color, "#"), user.avatar_color);
    let calls = profiles.load_profile_calls(pstore, user.account_id);
    guard let items = calls else let e = err_of(calls) { panic(e); }
    assert(len(items) == 3, to_str(len(items)));
    let statuses: [str] = [];
    for it in items { push(statuses, it.status); }
    let joined = strings.join(statuses, ",");
    assert(strings.contains(joined, "WON") && strings.contains(joined, "LOST") && strings.contains(joined, "OPEN"), joined);
    close_db(db);
}

import "crypto";
import "encoding";
import "pg";
import "proc";
import "time";
import "zokor";

fn deadline() -> until {
    return until_of(time.mono() + 10000000000);
}

fn live() -> opt[pg.Pool] {
    let none_here: opt[pg.Pool] = none;
    let url = proc.getenv("TEST_DATABASE_URL") ?? "";
    if len(url) == 0 {
        println("skip ledger postgres tests (TEST_DATABASE_URL is not set)");
        return none_here;
    }
    let m: map[str]str = {};
    m["DATABASE_URL"] = url;
    let opened = zokor.pg_from_config(zokor.config_from_values(m));
    guard let pool = opened else let e = err_of(opened) { panic(e); }
    let ms = zokor.load_migrations("migrations", zokor.migration_limits());
    guard let loaded = ms else let e = err_of(ms) { panic(e); }
    let applied = zokor.migrate(pool, loaded, deadline());
    guard let _n = applied else let e = err_of(applied) { panic(e); }
    let empty: [pg.Arg] = [];
    let s = pg.pool_query(pool,
        "insert into seasons (ordinal, starts_at, ends_at, status) " +
        "select (select coalesce(max(ordinal), 0) + 1 from seasons), now() - interval '1 day', " +
        "now() + interval '13 days', 'ACTIVE' " +
        "where not exists (select 1 from seasons where status = 'ACTIVE' " +
        "and starts_at <= now() and ends_at > now())",
        empty, deadline());
    guard let _s = s else let e = err_of(s) { panic(e); }
    return some(pool);
}

fn new_user(pool: pg.Pool) -> str {
    let rb = crypto.rand(6);
    guard let b = rb else { panic("rand"); }
    let name = "lg" + encoding.hex_encode(b);
    let email = name + "@test.say";
    let r: result[[IdRow], str] = zokor.query_all(pool,
        "insert into accounts (username, email, status) values ($1, $2, 'ACTIVE') returning id::text as id",
        [pg.arg_text(name), pg.arg_text(email)], deadline());
    guard let rows = r else let e = err_of(r) { panic(e); }
    return rows[0].id;
}

fn grant_tx(c: pg.Conn, account_id: str) -> result[int, str] {
    let r = post_signup_grant(c, account_id, 1000, deadline());
    guard let g = r else let e = err_of(r) { return err(e); }
    guard let grant = g else { return err("no active season"); }
    return ok(grant.amount);
}

gc struct SumRow {
    n: int
}

fn one_int(pool: pg.Pool, sql: str, id: str) -> int {
    let r: result[opt[SumRow], str] = zokor.query_one(pool, sql, [pg.arg_text(id)], deadline());
    guard let found = r else let e = err_of(r) { panic(e); }
    guard let row = found else { return -1; }
    return row.n;
}

fn test_should_post_one_balanced_grant_per_account_and_season() {
    guard let pool = live() else { return; }
    let id = new_user(pool);
    let first = zokor.transaction(pool, id, grant_tx, deadline());
    assert((first ?? 0) == 1000, inspect(first));
    let again = zokor.transaction(pool, id, grant_tx, deadline());
    assert((again ?? 0) == 1000, inspect(again));

    assert(one_int(pool, "select count(*)::bigint as n from issuance_grants where account_id = $1", id) == 1);
    assert(one_int(pool, "select free_units as n from wallets where account_id = $1", id) == 1000);
    assert(one_int(pool,
        "select count(*)::bigint as n from ledger_transactions t join issuance_grants g on g.journal_id = t.id " +
        "where g.account_id = $1", id) == 1);
    assert(one_int(pool,
        "select coalesce(sum(e.delta_units), 0)::bigint as n from ledger_entries e " +
        "join issuance_grants g on g.journal_id = e.transaction_id where g.account_id = $1", id) == 0);
}

fn test_should_report_the_active_season() {
    guard let pool = live() else { return; }
    let s = on_postgres(pool, 2000000000);
    let f = s.current;
    let r = f(s.context);
    guard let found = r else let e = err_of(r) { panic(e); }
    guard let season = found else { panic("no active season"); }
    assert(season.ordinal >= 1);
    assert(season.status == "ACTIVE");
}

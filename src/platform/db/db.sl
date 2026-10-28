import "pg";
import "zokor";
import "../cache" as cache;

struct PingRow {
    n: int
}

pub gc struct Db {
    pool: pg.Pool
}

pub fn open(cfg: zokor.Config) -> result[Db, str] {
    let r = zokor.pg_from_config(cfg);
    guard let pool = r else let e = err_of(r) {
        return err(e);
    }
    return ok(Db { pool: pool });
}

pub fn close(d: Db) {
    zokor.pg_close(d.pool);
}

pub fn reserved_pool(url: str,size: int) -> result[Db,str] {
    let opened=pg.new_pool(url,size);
    guard let pool=opened else let e=err_of(opened) { return err(e); }
    return ok(Db { pool:pool });
}

pub fn pool(d: Db) -> pg.Pool {
    return d.pool;
}

pub fn ping(d: Db, deadline: until) -> result[int, str] {
    let empty_args: [pg.Arg] = [];
    let r: result[[PingRow], str] = zokor.query_all(d.pool, "select 1 as n", empty_args, deadline);
    guard let _rows = r else let e = err_of(r) {
        return err(e);
    }
    return ok(0);
}

// A statement with no parameters and no rows wanted: setup and seeds.
pub fn run(d: Db, sql: str, deadline: until) -> result[int, str] {
    let none_args: [pg.Arg] = [];
    let r = pg.pool_query(d.pool, sql, none_args, deadline);
    guard let _rows = r else let e = err_of(r) {
        return err(e);
    }
    return ok(0);
}

// Sends legacy events through the same lease-based, outside-transaction path
// as runtime events.
pub fn publish_outbox(d: Db, c: cache.Cache, limit: int, timeout_ns: int) -> result[int, str] {
    return publish_legacy_outbox(d,c,limit,timeout_ns);
}

gc struct TextRow {
    t: str
}

// The first column of the first row, as text; "" when there is no row.
// Arguments go in as text, so a caller (a seed, a test) needs no pg types.
pub fn one_text(d: Db, sql: str, args: [str], deadline: until) -> result[str, str] {
    let pargs: [pg.Arg] = [];
    for a in args {
        push(pargs, pg.arg_text(a));
    }
    let r: result[[TextRow], str] = zokor.query_all(d.pool, sql, pargs, deadline);
    guard let rows = r else let e = err_of(r) {
        return err(e);
    }
    if len(rows) == 0 {
        return ok("");
    }
    return ok(rows[0].t);
}

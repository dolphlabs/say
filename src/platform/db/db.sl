import "pg";
import "time";
import "zokor";

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

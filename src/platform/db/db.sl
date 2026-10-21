import "pg";
import "time";
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

pub gc struct OutboxEvent {
    id: str,
    type: str,
    payload: str
}

gc struct PublishArg {
    cache: cache.Cache,
    limit: int,
    timeout: int
}

fn publish_tx(c: pg.Conn, a: PublishArg) -> result[int, str] {
    let d = until_of(time.mono() + a.timeout);
    let r: result[[OutboxEvent], str] = zokor.conn_query_all(c,
        "select id::text as id, type, payload::text as payload from outbox_events where published_at is null " +
        "order by created_at limit $1 for update skip locked", [pg.arg_int(a.limit)], d);
    guard let events = r else let e = err_of(r) {
        return err(e);
    }
    let sent = 0;
    for ev in events {
        let sr = cache.xadd(a.cache, "say:events", 100000, ["id", ev.id, "type", ev.type, "payload", ev.payload]);
        guard let _ok = sr else let e = err_of(sr) {
            let _u = pg.query(c, "update outbox_events set attempt_count = attempt_count + 1 where id = $1::uuid",
                              [pg.arg_text(ev.id)], d);
            return ok(sent);
        }
        let ur = pg.query(c, "update outbox_events set published_at = now(), attempt_count = attempt_count + 1 " +
                             "where id = $1::uuid", [pg.arg_text(ev.id)], d);
        guard let _u = ur else let e = err_of(ur) {
            return err(e);
        }
        sent += 1;
    }
    return ok(sent);
}

// Sends unpublished outbox events, oldest first, to the Redis stream
// say:events and stamps each one sent. Rows are locked while they are sent, so two instances
// never publish the same row; delivery is at least once (a crash after the
// sink and before COMMIT resends), so consumers dedupe on the event id.
pub fn publish_outbox(d: Db, c: cache.Cache, limit: int, timeout_ns: int) -> result[int, str] {
    return zokor.transaction(d.pool, PublishArg { cache: c, limit: limit, timeout: timeout_ns },
                             publish_tx, until_of(time.mono() + timeout_ns));
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

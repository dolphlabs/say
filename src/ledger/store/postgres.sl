import "pg";
import "redis";
import "time";
import "zokor";
import "../service" as service;

pub gc struct Leases {
    lock: mutex,
    conns: map[int]pg.Conn,
    next: int
}

pub gc struct Postgres {
    pool: pg.Pool,
    redis: opt[redis.Pool],
    timeout: int,
    redis_timeout: int,
    leases: Leases
}

pub fn new_postgres(pool: pg.Pool, cache: opt[redis.Pool], timeout_ns: int, redis_timeout_ns: int) -> Postgres {
    let conns: map[int]pg.Conn = {};
    return Postgres {
        pool: pool, redis: cache, timeout: timeout_ns, redis_timeout: redis_timeout_ns,
        leases: Leases { lock: make_mutex(), conns: conns, next: 1 }
    };
}

pub fn ledger_store(p: Postgres) -> service.LedgerStore[Postgres] {
    return service.LedgerStore[Postgres] {
        context: p,
        current: st_current,
        by_ordinal: st_by_ordinal,
        open_seasons: st_open_seasons,
        lease_try: st_lease_try,
        lease_release: st_lease_release,
        tick: st_tick,
        grant_run: st_grant_run,
        eligible_after: st_eligible_after,
        grant_chunk: st_grant_chunk,
        grant_advance: st_grant_advance,
        grant_finish: st_grant_finish,
        balance: st_balance,
        ledger_page: st_ledger_page,
        recon_request: st_recon_request,
        recon_run: st_recon_run,
        recon_latest: st_recon_latest,
        last_full_recon: st_last_full_recon,
        aggregate: st_aggregate,
        halt_state: st_halt_state,
        halt_clear: st_halt_clear,
        policy_propose: st_policy_propose,
        policy_approve: st_policy_approve,
        policies: st_policies
    };
}

fn deadline(p: Postgres) -> until {
    return until_of(time.mono() + p.timeout);
}

gc struct GotRow {
    got: bool
}

// The lock lives as long as its session, so the connection is held for the
// lease and closed (never pooled) if anything goes wrong with it.
fn st_lease_try(p: Postgres, key: int) -> result[opt[int], str] {
    let none_id: opt[int] = none;
    let cr = pg.acquire(p.pool, deadline(p));
    guard let conn = cr else let e = err_of(cr) {
        return err(e);
    }
    let r: result[[GotRow], str] = zokor.conn_query_all(conn, "select pg_try_advisory_lock($1) as got",
                                                       [pg.arg_int(key)], deadline(p));
    guard let rows = r else let e = err_of(r) {
        pg.close(conn);
        pg.release(p.pool, conn);
        return err(e);
    }
    if len(rows) != 1 || !rows[0].got {
        pg.release(p.pool, conn);
        return ok(none_id);
    }
    mutex_lock(p.leases.lock);
    let id = p.leases.next;
    p.leases.next = id + 1;
    p.leases.conns[id] = conn;
    mutex_unlock(p.leases.lock);
    return ok(some(id));
}

fn st_lease_release(p: Postgres, id: int) {
    mutex_lock(p.leases.lock);
    if !has(p.leases.conns, id) {
        mutex_unlock(p.leases.lock);
        return;
    }
    let conn = p.leases.conns[id];
    del(p.leases.conns, id);
    mutex_unlock(p.leases.lock);
    let none_args: [pg.Arg] = [];
    let r = pg.query(conn, "select pg_advisory_unlock_all()", none_args, deadline(p));
    if let _rows = r {
        pg.release(p.pool, conn);
        return;
    }
    pg.close(conn);
    pg.release(p.pool, conn);
}

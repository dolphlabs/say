import "builder";
import "json";
import "pg";
import "redis";
import "time";
import "timez";
import "zokor";
import "../domain" as domain;
import "../service" as service;

gc struct XidRow {
    xid: str
}

gc struct ClaimRow {
    id: str,
    scope: str
}

gc struct RunViewRow {
    id: str,
    scope: str,
    status: str,
    started_at: opt[timez.Time],
    finished_at: opt[timez.Time],
    ok: opt[bool],
    results: opt[str]
}

gc struct HaltRow {
    halted: bool,
    reason: opt[str],
    changed_at: timez.Time
}

gc struct TimeRow {
    at: opt[timez.Time]
}

gc struct Window {
    from: str,
    to: str
}

fn halt_key() -> str {
    return "say:trading_halted";
}

fn mirror_halt(p: Postgres, halted: bool) {
    guard let pool = p.redis else {
        return;
    }
    let d = until_of(time.mono() + p.redis_timeout);
    let cr = redis.acquire(pool, d);
    guard let conn = cr else {
        return;
    }
    let v = "0";
    if halted {
        v = "1";
    }
    let _r = redis.do(conn, [to_bytes("SET"), to_bytes(halt_key()), to_bytes(v)], d);
    redis.release(pool, conn);
}

fn count_of(p: Postgres, sql: str, w: Window) -> result[int, str] {
    let r: result[[CountRow], str] = zokor.query_all(p.pool, sql, [pg.arg_text(w.from), pg.arg_text(w.to)],
                                                    until_of(time.mono() + p.timeout * 30));
    guard let rows = r else let e = err_of(r) {
        return err(e);
    }
    return ok(rows[0].n);
}

fn check(p: Postgres, name: str, sql: str, w: Window, what: str) -> domain.Check {
    let r = count_of(p, sql, w);
    guard let n = r else let e = err_of(r) {
        return domain.failed(name, -1, "check could not run: " + e);
    }
    if n == 0 {
        return domain.passed(name);
    }
    return domain.failed(name, n, to_str(n) + " " + what);
}

fn in_window() -> str {
    return "(select t.id from ledger_transactions t where t.xid >= $1::xid8 and t.xid < $2::xid8)";
}

// The six checks the treasury screen shows, plus the three that need the
// exchange. Each counts violations; zero passes. `w` limits the scan to
// transactions that finished in [from, to).
fn run_checks(p: Postgres, w: Window) -> [domain.Check] {
    let out: [domain.Check] = [];
    push(out, check(p, "entries_balance",
        "select count(*)::bigint as n from (select e.transaction_id from ledger_entries e " +
        "where e.transaction_id in (select t.id from ledger_transactions t where t.xid >= $1::xid8 and t.xid < $2::xid8) " +
        "group by e.transaction_id, e.asset_key having sum(e.delta) <> 0 " +
        "union all select t.id from ledger_transactions t where t.xid >= $1::xid8 and t.xid < $2::xid8 " +
        "and (select count(*) from ledger_entries e where e.transaction_id = t.id) < 2) x",
        w, "transactions do not sum to zero per asset"));
    push(out, check(p, "cached_balances",
        "select count(*)::bigint as n from wallets w join (select e.wallet_id, " +
        "coalesce(sum(e.delta) filter (where e.bucket = 'free'), 0) as f, " +
        "coalesce(sum(e.delta) filter (where e.bucket = 'held'), 0) as h from ledger_entries e " +
        "where e.wallet_id in (select e2.wallet_id from ledger_entries e2 join ledger_transactions t on t.id = e2.transaction_id " +
        "where t.xid >= $1::xid8 and t.xid < $2::xid8) group by e.wallet_id) s on s.wallet_id = w.id " +
        "where w.owner_kind <> 'system' and (w.free_units <> s.f or w.held_units <> s.h)",
        w, "wallets' cached balances differ from their entries"));
    push(out, check(p, "no_negative_balances",
        "select count(*)::bigint as n from wallets where owner_kind <> 'system' and (free_units < 0 or held_units < 0) " +
        "and $1::xid8 is not null and $2::xid8 is not null",
        w, "user or bot wallets are negative"));
    push(out, check(p, "grants",
        "select count(*)::bigint as n from (select g.season_id from issuance_grants g " +
        "join issuance_policies pol on pol.id = g.policy_id " +
        "left join ledger_transactions t on t.business_key = g.business_key and t.kind = 'SEASON_GRANT' " +
        "where $1::xid8 is not null and $2::xid8 is not null " +
        "group by g.season_id having count(t.id) <> count(*) or bool_or(g.amount <> pol.amount) " +
        "or sum(g.amount) <> coalesce((select -sum(e.delta) from ledger_entries e join ledger_transactions t2 " +
        "on t2.id = e.transaction_id join wallets iw on iw.id = e.wallet_id where t2.kind = 'SEASON_GRANT' " +
        "and t2.season_id = g.season_id and iw.owner_id = 'system:issuance'), 0) " +
        "or sum(g.amount) <> coalesce((select max(p2.season_cap) - sum(b.remaining) from issuance_budget b " +
        "join issuance_policies p2 on p2.id = b.policy_id where b.season_id = g.season_id), sum(g.amount))) x",
        w, "seasons whose grants disagree with their postings or their budget"));
    push(out, check(p, "season_isolation",
        "select count(*)::bigint as n from ledger_entries e join ledger_transactions t on t.id = e.transaction_id " +
        "join wallets w on w.id = e.wallet_id where t.xid >= $1::xid8 and t.xid < $2::xid8 " +
        "and (e.season_id <> t.season_id or w.season_id <> t.season_id)",
        w, "entries touch a wallet from another season"));
    push(out, check(p, "holds",
        "select (select count(*) from holds h left join (select hold_id, sum(delta) as s from ledger_entries " +
        "where hold_id is not null group by hold_id) x on x.hold_id = h.id " +
        "where h.amount_held - h.amount_consumed - h.amount_released <> coalesce(x.s, 0) " +
        "and h.wallet_id in (select e.wallet_id from ledger_entries e join ledger_transactions t on t.id = e.transaction_id " +
        "where t.xid >= $1::xid8 and t.xid < $2::xid8)) + " +
        "(select count(*) from wallets w left join (select wallet_id, sum(amount_held - amount_consumed - amount_released) as r " +
        "from holds where status = 'open' group by wallet_id) o on o.wallet_id = w.id " +
        "where w.owner_kind <> 'system' and w.held_units <> coalesce(o.r, 0) " +
        "and w.id in (select e.wallet_id from ledger_entries e join ledger_transactions t on t.id = e.transaction_id " +
        "where t.xid >= $1::xid8 and t.xid < $2::xid8)) as n",
        w, "holds disagree with their entries or their wallet's held balance"));
    push(out, domain.not_yet("yes_no_supply", "prompt 05"));
    push(out, domain.not_yet("collateral", "prompt 05"));
    push(out, domain.not_yet("fee_once", "prompt 05"));
    return out;
}

fn checks_json(checks: [domain.Check]) -> str {
    return json.encode(checks);
}

fn st_recon_request(p: Postgres, requested_by: str) -> result[str, str] {
    let r: result[[IdRow], str] = zokor.query_all(p.pool,
        "insert into reconciliation_runs (scope, status, requested_by) values ('full', 'pending', nullif($1, '')::uuid) " +
        "returning id::text as id", [pg.arg_text(requested_by)], deadline(p));
    guard let rows = r else let e = err_of(r) {
        return err(e);
    }
    return ok(rows[0].id);
}

gc struct RecordArg {
    id: str,
    scope: str,
    window: Window,
    checks: [domain.Check],
    timeout: int
}

fn record_tx(c: pg.Conn, a: RecordArg) -> result[bool, str] {
    let d = until_of(time.mono() + a.timeout);
    let good = domain.all_ok(a.checks);
    let ur = exec(c,
        "update reconciliation_runs set status = 'done', finished_at = now(), results = $2::jsonb, ok = $3, " +
        "from_xid = $4::xid8, to_xid = $5::xid8 where id = $1::uuid",
        [pg.arg_text(a.id), pg.arg_text(checks_json(a.checks)), pg.arg_bool(good), pg.arg_text(a.window.from),
         pg.arg_text(a.window.to)], d);
    guard let _u = ur else let e = err_of(ur) {
        return err(e);
    }
    let wr = exec(c, "update ledger_watermarks set xid = greatest(xid, $1::xid8) where name = 'recon'",
                  [pg.arg_text(a.window.to)], d);
    guard let _w = wr else let e = err_of(wr) {
        return err(e);
    }
    if good {
        return ok(true);
    }
    let failed = builder.new_str();
    for ck in a.checks {
        if ck.status == "failed" {
            if !failed.is_empty() {
                failed.write(", ");
            }
            failed.write(ck.name);
        }
    }
    let reason = "reconciliation " + a.id + " failed: " + failed.finish();
    let hr = exec(c, "update trading_halt set halted = true, reason = $1, changed_at = now(), changed_by = null where id = 1",
                  [pg.arg_text(reason)], d);
    guard let _h = hr else let e = err_of(hr) {
        return err(e);
    }
    let er = emit(c, "reconciliation.failed", zokor.jobj().set_str("run_id", a.id).set_str("reason", reason), d);
    guard let _e = er else let e = err_of(er) {
        return err(e);
    }
    return ok(false);
}

// Claims a requested run, or starts a scheduled one, runs every check over
// its window, and records it. A failure halts trading in the same
// transaction that records it.
fn st_recon_run(p: Postgres, full: bool) -> result[opt[service.ReconRun], str] {
    let none_args: [pg.Arg] = [];
    let cr: result[[ClaimRow], str] = zokor.query_all(p.pool,
        "update reconciliation_runs set status = 'running', started_at = now() where id = " +
        "(select id from reconciliation_runs where status = 'pending' order by created_at limit 1 for update skip locked) " +
        "returning id::text as id, scope", none_args, deadline(p));
    guard let claimed = cr else let e = err_of(cr) {
        return err(e);
    }
    let id = "";
    let scope = "incremental";
    if full {
        scope = "full";
    }
    if len(claimed) > 0 {
        id = claimed[0].id;
        scope = claimed[0].scope;
    } else {
        let ir: result[[IdRow], str] = zokor.query_all(p.pool,
            "insert into reconciliation_runs (scope, status, started_at) values ($1, 'running', now()) returning id::text as id",
            [pg.arg_text(scope)], deadline(p));
        guard let inserted = ir else let e = err_of(ir) {
            return err(e);
        }
        id = inserted[0].id;
    }
    let wr: result[[Window], str] = zokor.query_all(p.pool,
        "select (case when $1 = 'full' then '0'::xid8 else (select xid from ledger_watermarks where name = 'recon') end)::text as from, " +
        "pg_snapshot_xmin(pg_current_snapshot())::text as to", [pg.arg_text(scope)], deadline(p));
    guard let windows = wr else let e = err_of(wr) {
        return err(e);
    }
    let w = windows[0];
    let checks = run_checks(p, w);
    let rr = zokor.transaction(p.pool, RecordArg { id: id, scope: scope, window: w, checks: checks, timeout: p.timeout },
                               record_tx, until_of(time.mono() + p.timeout));
    guard let good = rr else let e = err_of(rr) {
        return err(e);
    }
    if !good {
        mirror_halt(p, true);
    }
    return st_run_by_id(p, id);
}

fn to_recon(r: RunViewRow) -> service.ReconRun {
    let checks: [domain.Check] = [];
    if let text = r.results {
        let dr: result[[domain.Check], str] = json.decode(text);
        if let parsed = dr {
            checks = parsed;
        }
    }
    return service.ReconRun { id: r.id, scope: r.scope, status: r.status, started_at: r.started_at,
                              finished_at: r.finished_at, ok: r.ok, checks: checks };
}

fn st_run_by_id(p: Postgres, id: str) -> result[opt[service.ReconRun], str] {
    let r: result[opt[RunViewRow], str] = zokor.query_one(p.pool,
        "select id::text as id, scope, status, started_at, finished_at, ok, results::text as results " +
        "from reconciliation_runs where id = $1::uuid", [pg.arg_text(id)], deadline(p));
    guard let found = r else let e = err_of(r) {
        return err(e);
    }
    let none_run: opt[service.ReconRun] = none;
    guard let row = found else {
        return ok(none_run);
    }
    return ok(some(to_recon(row)));
}

fn st_recon_latest(p: Postgres) -> result[opt[service.ReconRun], str] {
    let none_args: [pg.Arg] = [];
    let r: result[opt[RunViewRow], str] = zokor.query_one(p.pool,
        "select id::text as id, scope, status, started_at, finished_at, ok, results::text as results " +
        "from reconciliation_runs where status = 'done' order by finished_at desc limit 1", none_args, deadline(p));
    guard let found = r else let e = err_of(r) {
        return err(e);
    }
    let none_run: opt[service.ReconRun] = none;
    guard let row = found else {
        return ok(none_run);
    }
    return ok(some(to_recon(row)));
}

fn st_last_full_recon(p: Postgres) -> result[opt[timez.Time], str] {
    let none_args: [pg.Arg] = [];
    let r: result[[TimeRow], str] = zokor.query_all(p.pool,
        "select max(finished_at) as at from reconciliation_runs where scope = 'full' and status = 'done'",
        none_args, deadline(p));
    guard let rows = r else let e = err_of(r) {
        return err(e);
    }
    return ok(rows[0].at);
}

gc struct AggArg {
    timeout: int
}

gc struct AggWindowRow {
    from: str,
    to: str,
    ahead: bool
}

// Folds system-wallet entries of every transaction that finished since the
// last pass into system_balances. Transactions below the snapshot's xmin
// are all finished, so nothing committed late is ever skipped.
fn aggregate_tx(c: pg.Conn, a: AggArg) -> result[int, str] {
    let d = until_of(time.mono() + a.timeout);
    let none_args: [pg.Arg] = [];
    let wr: result[[AggWindowRow], str] = zokor.conn_query_all(c,
        "select xid::text as from, pg_snapshot_xmin(pg_current_snapshot())::text as to, " +
        "pg_snapshot_xmin(pg_current_snapshot()) > xid as ahead from ledger_watermarks where name = 'aggregate' for update",
        none_args, d);
    guard let ws = wr else let e = err_of(wr) {
        return err(e);
    }
    if len(ws) != 1 || !ws[0].ahead {
        return ok(0);
    }
    let w = ws[0];
    let r: result[[CountRow], str] = zokor.conn_query_all(c,
        "with moved as (insert into system_balances (wallet_id, season_id, owner_id, asset_key, balance, as_of) " +
        "select e.wallet_id, w.season_id, w.owner_id, w.asset_key, sum(e.delta), now() " +
        "from ledger_entries e join ledger_transactions t on t.id = e.transaction_id join wallets w on w.id = e.wallet_id " +
        "where w.owner_kind = 'system' and t.xid >= $1::xid8 and t.xid < $2::xid8 " +
        "group by e.wallet_id, w.season_id, w.owner_id, w.asset_key " +
        "on conflict (wallet_id) do update set balance = system_balances.balance + excluded.balance, as_of = excluded.as_of " +
        "returning 1) select count(*)::bigint as n from moved",
        [pg.arg_text(w.from), pg.arg_text(w.to)], d);
    guard let moved = r else let e = err_of(r) {
        return err(e);
    }
    let ur = exec(c, "update ledger_watermarks set xid = $1::xid8 where name = 'aggregate'", [pg.arg_text(w.to)], d);
    guard let _u = ur else let e = err_of(ur) {
        return err(e);
    }
    return ok(moved[0].n);
}

fn st_aggregate(p: Postgres) -> result[int, str] {
    return zokor.transaction(p.pool, AggArg { timeout: p.timeout * 10 }, aggregate_tx,
                             until_of(time.mono() + p.timeout * 10));
}

fn st_halt_state(p: Postgres) -> result[service.Halt, str] {
    let none_args: [pg.Arg] = [];
    let r: result[[HaltRow], str] = zokor.query_all(p.pool,
        "select halted, reason, changed_at from trading_halt where id = 1", none_args, deadline(p));
    guard let rows = r else let e = err_of(r) {
        return err(e);
    }
    if len(rows) != 1 {
        return err("trading_halt row missing");
    }
    return ok(service.Halt { halted: rows[0].halted, reason: rows[0].reason ?? "", changed_at: rows[0].changed_at });
}

gc struct ClearArg {
    actor: str,
    reason: str,
    timeout: int
}

fn clear_tx(c: pg.Conn, a: ClearArg) -> result[bool, str] {
    let d = until_of(time.mono() + a.timeout);
    let ur = exec(c, "update trading_halt set halted = false, reason = $2, changed_at = now(), changed_by = $1::uuid where id = 1",
                  [pg.arg_text(a.actor), pg.arg_text(a.reason)], d);
    guard let _u = ur else let e = err_of(ur) {
        return err(e);
    }
    let ar = exec(c, "insert into audit_events (actor_id, action, target_type, target_id, detail) " +
                     "values ($1::uuid, 'trading_halt.clear', 'trading_halt', '1', $2::jsonb)",
                  [pg.arg_text(a.actor), pg.arg_text(zokor.jobj().set_str("reason", a.reason).render())], d);
    guard let _a = ar else let e = err_of(ar) {
        return err(e);
    }
    return ok(true);
}

fn st_halt_clear(p: Postgres, actor: str, reason: str) -> result[bool, str] {
    let r = zokor.transaction(p.pool, ClearArg { actor: actor, reason: reason, timeout: p.timeout }, clear_tx,
                              until_of(time.mono() + p.timeout));
    guard let _ok = r else let e = err_of(r) {
        return err(e);
    }
    mirror_halt(p, false);
    return ok(true);
}

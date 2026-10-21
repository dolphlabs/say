import "pg";
import "strings";
import "time";
import "timez";
import "zokor";
import "../domain" as domain;
import "../service" as service;

gc struct PolicyRow {
    id: str,
    amount: int,
    season_cap: int
}

gc struct GrantedRow {
    granted: int
}

gc struct AmountRow {
    amount: int
}

gc struct RunRow {
    season_id: str,
    last_account_id: opt[str],
    granted: int,
    skipped: int,
    finished: bool,
    halted_reason: opt[str]
}

pub gc struct GrantBatch {
    granted: [str],
    skipped: int,
    amount: int,
    halt: str
}

fn approved_policy(c: pg.Conn, d: until) -> result[opt[PolicyRow], str] {
    let none_args: [pg.Arg] = [];
    let r: result[[PolicyRow], str] = zokor.conn_query_all(c,
        "select id::text as id, amount, season_cap from issuance_policies where status = 'APPROVED'", none_args, d);
    guard let rows = r else let e = err_of(r) {
        return err(e);
    }
    let none_row: opt[PolicyRow] = none;
    if len(rows) == 0 {
        return ok(none_row);
    }
    return ok(some(rows[0]));
}

fn seed_budget(c: pg.Conn, season_id: str, policy: PolicyRow, d: until) -> result[int, str] {
    let shards: [int] = [];
    let amounts: [int] = [];
    for i in 0..domain.budget_shards() {
        push(shards, i);
        push(amounts, domain.shard_budget(policy.season_cap, policy.amount, i));
    }
    return exec(c,
        "insert into issuance_budget (season_id, shard, policy_id, remaining) " +
        "select $1::uuid, v.s, $2::uuid, v.r from unnest($3::smallint[], $4::bigint[]) as v(s, r) " +
        "order by v.s on conflict (season_id, shard) do nothing",
        [pg.arg_text(season_id), pg.arg_text(policy.id), pg.arg_text(int_array(shards)), pg.arg_text(int_array(amounts))], d);
}

pub fn seed_budget_if_approved(c: pg.Conn, season_id: str, d: until) -> result[int, str] {
    let pr = approved_policy(c, d);
    guard let found = pr else let e = err_of(pr) {
        return err(e);
    }
    guard let policy = found else {
        return ok(0);
    }
    return seed_budget(c, season_id, policy, d);
}

gc struct RemainingRow {
    remaining: int
}

fn budget_rows(c: pg.Conn, season_id: str, d: until) -> result[int, str] {
    let r: result[[CountRow], str] = zokor.conn_query_all(c,
        "select count(*)::bigint as n from issuance_budget where season_id = $1::uuid", [pg.arg_text(season_id)], d);
    guard let rows = r else let e = err_of(r) {
        return err(e);
    }
    return ok(rows[0].n);
}

// One grant from one shard: the update locks nothing when the shard is
// short, so a grant never holds two shard rows.
fn take_one(c: pg.Conn, season_id: str, policy: PolicyRow, first: int, d: until) -> result[int, str] {
    for i in 0..domain.budget_shards() {
        let shard = (first + i) % domain.budget_shards();
        let r: result[[RemainingRow], str] = zokor.conn_query_all(c,
            "update issuance_budget set remaining = remaining - $3 " +
            "where season_id = $1::uuid and shard = $2 and remaining >= $3 returning remaining",
            [pg.arg_text(season_id), pg.arg_int(shard), pg.arg_int(policy.amount)], d);
        guard let rows = r else let e = err_of(r) {
            return err(e);
        }
        if len(rows) == 1 {
            return ok(1);
        }
    }
    return ok(0);
}

// Several grants (a rollover chunk): shards in ascending order, so two
// chunks never wait on each other in a cycle.
fn take_many(c: pg.Conn, season_id: str, policy: PolicyRow, want: int, d: until) -> result[int, str] {
    let taken = 0;
    for shard in 0..domain.budget_shards() {
        if taken == want {
            break;
        }
        let r: result[[RemainingRow], str] = zokor.conn_query_all(c,
            "select remaining from issuance_budget where season_id = $1::uuid and shard = $2 for update",
            [pg.arg_text(season_id), pg.arg_int(shard)], d);
        guard let rows = r else let e = err_of(r) {
            return err(e);
        }
        if len(rows) == 0 {
            continue;
        }
        let n = rows[0].remaining / policy.amount;
        if n > want - taken {
            n = want - taken;
        }
        if n == 0 {
            continue;
        }
        let ur = exec(c, "update issuance_budget set remaining = remaining - $3 where season_id = $1::uuid and shard = $2",
                      [pg.arg_text(season_id), pg.arg_int(shard), pg.arg_int(n * policy.amount)], d);
        guard let _u = ur else let e = err_of(ur) {
            return err(e);
        }
        taken = taken + n;
    }
    return ok(taken);
}

// Funds `want` grants from the season's budget, seeding it from the policy
// the first time. Taken last in the grant's transaction, so a shard row is
// locked only from here to COMMIT.
fn take_budget(c: pg.Conn, season_id: str, policy: PolicyRow, want: int, first: int, d: until) -> result[int, str] {
    for attempt in 0..2 {
        let r: result[int, str] = ok(0);
        if want == 1 {
            r = take_one(c, season_id, policy, first, d);
        } else {
            r = take_many(c, season_id, policy, want, d);
        }
        guard let taken = r else let e = err_of(r) {
            return err(e);
        }
        if taken > 0 || attempt == 1 {
            return ok(taken);
        }
        // Nothing funded: the budget may be spent, or not seeded yet, or
        // seeded by a transaction that committed after this one looked.
        // Seed if it is missing, then look once more before calling the
        // cap reached.
        let br = budget_rows(c, season_id, d);
        guard let rows = br else let e = err_of(br) {
            return err(e);
        }
        if rows == 0 {
            let sr = seed_budget(c, season_id, policy, d);
            guard let _s = sr else let e = err_of(sr) {
                return err(e);
            }
        }
    }
    return ok(0);
}

fn claim(c: pg.Conn, season_id: str, policy: PolicyRow, ids: [str], d: until) -> result[[str], str] {
    let r: result[[IdRow], str] = zokor.conn_query_all(c,
        "insert into issuance_grants (account_id, season_id, amount, policy_id, business_key) " +
        "select a.id, $1::uuid, $2, $3::uuid, 'grant:' || $1 || ':' || a.id::text from accounts a " +
        "where a.id = any($4::uuid[]) and a.kind = 'USER' and a.status = 'ACTIVE' " +
        "and a.email_verified_at is not null and a.deleted_at is null " +
        "order by a.id on conflict (account_id, season_id) do nothing returning account_id::text as id",
        [pg.arg_text(season_id), pg.arg_int(policy.amount), pg.arg_text(policy.id), pg.arg_text(text_array(ids))], d);
    guard let rows = r else let e = err_of(r) {
        return err(e);
    }
    let out: [str] = [];
    for row in rows {
        push(out, row.id);
    }
    return ok(sort_ids(out));
}

fn sort_ids(xs: [str]) -> [str] {
    for i in 1..len(xs) {
        let j = i;
        while j > 0 && xs[j] < xs[j - 1] {
            let t = xs[j];
            xs[j] = xs[j - 1];
            xs[j - 1] = t;
            j = j - 1;
        }
    }
    return xs;
}

fn first_n(xs: [str], n: int) -> [str] {
    let out: [str] = [];
    for i in 0..n {
        push(out, xs[i]);
    }
    return out;
}

fn sql_step(c: pg.Conn, sql: str, d: until) -> opt[domain.LedgerError] {
    let none_args: [pg.Arg] = [];
    let r = exec(c, sql, none_args, d);
    guard let _ok = r else let e = err_of(r) {
        return some(store_err(e));
    }
    return none;
}

// Grants this season's allowance to each eligible account in `ids` that
// has none yet, all in the caller's transaction. One path for verification
// (one id) and the rollover (a chunk): claim, fund from the budget, post.
// The claim row's key references the ledger transaction through a deferred
// foreign key, so a claim can never commit without its posting.
pub fn grant_accounts(c: pg.Conn, season_id: str, ids: [str], d: until) -> result[GrantBatch, domain.LedgerError] {
    let none_ids: [str] = [];
    let pr = approved_policy(c, d);
    guard let found = pr else let e = err_of(pr) {
        return err(store_err(e));
    }
    guard let policy = found else {
        return ok(GrantBatch { granted: none_ids, skipped: len(ids), amount: 0, halt: "no approved issuance policy" });
    }
    if let e = sql_step(c, "savepoint ledger_grant", d) {
        return err(e);
    }
    let want = ids;
    let halt = "";
    let claimed: [str] = [];
    while true {
        let cr = claim(c, season_id, policy, want, d);
        guard let got = cr else let e = err_of(cr) {
            return err(store_err(e));
        }
        claimed = got;
        if len(claimed) == 0 {
            break;
        }
        let txs: [domain.LedgerTx] = [];
        for id in claimed {
            push(txs, domain.grant_tx(id, season_id, policy.amount));
        }
        let posted = post_many(c, txs, d);
        guard let _p = posted else let e = err_of(posted) {
            let _r = sql_step(c, "rollback to savepoint ledger_grant", d);
            return err(e);
        }
        let tr = take_budget(c, season_id, policy, len(claimed), domain.shard_of(claimed[0]), d);
        guard let funded = tr else let e = err_of(tr) {
            return err(store_err(e));
        }
        if funded == len(claimed) {
            break;
        }
        halt = "issuance cap reached";
        if let e = sql_step(c, "rollback to savepoint ledger_grant", d) {
            return err(e);
        }
        if funded == 0 {
            claimed = none_ids;
            break;
        }
        want = first_n(claimed, funded);
    }
    if let e = sql_step(c, "release savepoint ledger_grant", d) {
        return err(e);
    }
    return ok(GrantBatch { granted: claimed, skipped: len(ids) - len(claimed), amount: policy.amount, halt: halt });
}

// ledger.grant_season_allowance: the S 1,000 for one account in one season,
// at most once, in the caller's transaction. none when the season is not
// active, there is no approved policy, or the cap is reached; the rollover
// picks the account up later in the first two cases.
pub fn grant_season_allowance(c: pg.Conn, account_id: str, season_id: str, d: until) -> result[opt[domain.Grant], domain.LedgerError] {
    let none_grant: opt[domain.Grant] = none;
    let sr: result[[SeasonRow], str] = zokor.conn_query_all(c,
        "select id::text as id, ordinal, starts_at, ends_at, status from seasons where id = $1::uuid",
        [pg.arg_text(season_id)], d);
    guard let seasons = sr else let e = err_of(sr) {
        return err(store_err(e));
    }
    if len(seasons) == 0 || seasons[0].status != domain.active() {
        return ok(none_grant);
    }
    let s = seasons[0];
    let er: result[[AmountRow], str] = zokor.conn_query_all(c,
        "select amount from issuance_grants where account_id = $1::uuid and season_id = $2::uuid",
        [pg.arg_text(account_id), pg.arg_text(season_id)], d);
    guard let had = er else let e = err_of(er) {
        return err(store_err(e));
    }
    if len(had) > 0 {
        return ok(some(domain.Grant { amount: had[0].amount, season_ordinal: s.ordinal, season_ends_at: s.ends_at }));
    }
    let br = grant_accounts(c, season_id, [account_id], d);
    guard let batch = br else let e = err_of(br) {
        return err(e);
    }
    if len(batch.granted) == 1 {
        return ok(some(domain.Grant { amount: batch.amount, season_ordinal: s.ordinal, season_ends_at: s.ends_at }));
    }
    let again: result[[AmountRow], str] = zokor.conn_query_all(c,
        "select amount from issuance_grants where account_id = $1::uuid and season_id = $2::uuid",
        [pg.arg_text(account_id), pg.arg_text(season_id)], d);
    guard let raced = again else let e = err_of(again) {
        return err(store_err(e));
    }
    if len(raced) > 0 {
        return ok(some(domain.Grant { amount: raced[0].amount, season_ordinal: s.ordinal, season_ends_at: s.ends_at }));
    }
    return ok(none_grant);
}

// The active season's grant for an account verifying now (prompt 01's
// verify and Google-complete transactions call this).
pub fn grant_current_season(c: pg.Conn, account_id: str, d: until) -> result[opt[domain.Grant], domain.LedgerError] {
    let none_args: [pg.Arg] = [];
    let sr: result[[SeasonIdRow], str] = zokor.conn_query_all(c,
        "select id::text as season_id from seasons where status = 'ACTIVE' and starts_at <= now() and ends_at > now()",
        none_args, d);
    guard let rows = sr else let e = err_of(sr) {
        return err(store_err(e));
    }
    if len(rows) == 0 {
        let none_grant: opt[domain.Grant] = none;
        return ok(none_grant);
    }
    return grant_season_allowance(c, account_id, rows[0].season_id, d);
}

pub fn no_grant() -> opt[domain.Grant] {
    let g: opt[domain.Grant] = none;
    return g;
}

fn to_run(r: RunRow) -> service.GrantRun {
    return service.GrantRun {
        season_id: r.season_id, last_account_id: r.last_account_id ?? "", granted: r.granted, skipped: r.skipped,
        finished: r.finished, halted_reason: r.halted_reason ?? ""
    };
}

fn st_grant_run(p: Postgres, season_id: str) -> result[service.GrantRun, str] {
    let ir = pg.pool_query(p.pool, "insert into grant_runs (season_id) values ($1::uuid) on conflict (season_id) do nothing",
                           [pg.arg_text(season_id)], deadline(p));
    guard let _i = ir else let e = err_of(ir) {
        return err(e);
    }
    let r: result[opt[RunRow], str] = zokor.query_one(p.pool,
        "select season_id::text as season_id, last_account_id::text as last_account_id, granted, skipped, " +
        "finished_at is not null as finished, halted_reason from grant_runs where season_id = $1::uuid",
        [pg.arg_text(season_id)], deadline(p));
    guard let found = r else let e = err_of(r) {
        return err(e);
    }
    guard let row = found else {
        return err("grant run missing for " + season_id);
    }
    return ok(to_run(row));
}

fn st_eligible_after(p: Postgres, cursor: str, limit: int) -> result[[str], str] {
    let after = cursor;
    if len(after) == 0 {
        after = "00000000-0000-0000-0000-000000000000";
    }
    let r: result[[IdRow], str] = zokor.query_all(p.pool,
        "select id::text as id from accounts where kind = 'USER' and status = 'ACTIVE' " +
        "and email_verified_at is not null and deleted_at is null and id > $1::uuid order by id limit $2",
        [pg.arg_text(after), pg.arg_int(limit)], deadline(p));
    guard let rows = r else let e = err_of(r) {
        return err(e);
    }
    let out: [str] = [];
    for row in rows {
        push(out, row.id);
    }
    return ok(out);
}

gc struct ChunkArg {
    season_id: str,
    ids: [str],
    timeout: int
}

fn chunk_tx(c: pg.Conn, a: ChunkArg) -> result[service.ChunkResult, str] {
    let d = until_of(time.mono() + a.timeout);
    let br = grant_accounts(c, a.season_id, a.ids, d);
    guard let batch = br else let e = err_of(br) {
        return err(domain.encode(e));
    }
    let ur = exec(c, "update grant_runs set granted = granted + $2, skipped = skipped + $3 where season_id = $1::uuid",
                  [pg.arg_text(a.season_id), pg.arg_int(len(batch.granted)), pg.arg_int(batch.skipped)], d);
    guard let _u = ur else let e = err_of(ur) {
        return err(e);
    }
    return ok(service.ChunkResult { granted: len(batch.granted), skipped: batch.skipped, halt: batch.halt });
}

// One chunk, one transaction: a crash loses at most this chunk's work,
// and redoing it grants nobody twice.
fn st_grant_chunk(p: Postgres, season_id: str, ids: [str]) -> result[service.ChunkResult, str] {
    let budget = p.timeout * 10;
    return zokor.transaction(p.pool, ChunkArg { season_id: season_id, ids: ids, timeout: budget }, chunk_tx,
                             until_of(time.mono() + budget));
}

fn st_grant_advance(p: Postgres, season_id: str, cursor: str) -> result[bool, str] {
    let r = pg.pool_query(p.pool, "update grant_runs set last_account_id = $2::uuid where season_id = $1::uuid",
                          [pg.arg_text(season_id), pg.arg_text(cursor)], deadline(p));
    guard let _rows = r else let e = err_of(r) {
        return err(e);
    }
    return ok(true);
}

gc struct FinishArg {
    season_id: str,
    halt: str,
    timeout: int
}

fn finish_tx(c: pg.Conn, a: FinishArg) -> result[service.GrantRun, str] {
    let d = until_of(time.mono() + a.timeout);
    let r: result[[RunRow], str] = zokor.conn_query_all(c,
        "update grant_runs set finished_at = now(), halted_reason = nullif($2, ''), " +
        "granted = (select count(*) from issuance_grants g where g.season_id = $1::uuid) " +
        "where season_id = $1::uuid returning season_id::text as season_id, last_account_id::text as last_account_id, " +
        "granted, skipped, finished_at is not null as finished, halted_reason",
        [pg.arg_text(a.season_id), pg.arg_text(a.halt)], d);
    guard let rows = r else let e = err_of(r) {
        return err(e);
    }
    if len(rows) != 1 {
        return err("grant run missing for " + a.season_id);
    }
    let run = to_run(rows[0]);
    let ev = zokor.jobj().set_str("season_id", a.season_id).set_int("granted", run.granted)
        .set_int("skipped", run.skipped);
    if len(a.halt) > 0 {
        ev.set_str("halted_reason", a.halt);
        let ar = emit(c, "alert.issuance_halted", ev, d);
        guard let _a = ar else let e = err_of(ar) {
            return err(e);
        }
    }
    let er = emit(c, "season.grants_done", ev, d);
    guard let _e = er else let e = err_of(er) {
        return err(e);
    }
    return ok(run);
}

fn st_grant_finish(p: Postgres, season_id: str, halt: str) -> result[service.GrantRun, str] {
    return zokor.transaction(p.pool, FinishArg { season_id: season_id, halt: halt, timeout: p.timeout }, finish_tx,
                             until_of(time.mono() + p.timeout));
}

gc struct PolicyViewRow {
    id: str,
    amount: int,
    season_cap: int,
    status: str,
    proposed_by: str,
    approvals: str
}

fn to_view(r: PolicyViewRow) -> service.PolicyView {
    let approvals: [str] = [];
    if len(r.approvals) > 0 {
        approvals = strings.split(r.approvals, ",");
    }
    return service.PolicyView { id: r.id, amount: r.amount, season_cap: r.season_cap, status: r.status,
                                proposed_by: r.proposed_by, approvals: approvals };
}

fn is_operator_sql() -> str {
    return "select count(*)::bigint as n from account_roles where account_id = $1::uuid and role in ('admin', 'super_admin')";
}

fn st_policy_propose(p: Postgres, amount: int, cap: int, operator: str) -> result[str, str] {
    let r: result[[IdRow], str] = zokor.query_all(p.pool,
        "insert into issuance_policies (amount, season_cap, status, proposed_by) " +
        "select $1, $2, 'PROPOSED', $3::uuid " +
        "where exists (select 1 from account_roles where account_id = $3::uuid and role in ('admin', 'super_admin')) " +
        "returning id::text as id",
        [pg.arg_int(amount), pg.arg_int(cap), pg.arg_text(operator)], deadline(p));
    guard let rows = r else let e = err_of(r) {
        return err(e);
    }
    if len(rows) == 0 {
        return err("operator " + operator + " has no admin role");
    }
    return ok(rows[0].id);
}

gc struct ApproveArg {
    policy_id: str,
    operator: str,
    timeout: int
}

// Two distinct operators make a policy APPROVED; it replaces the previous
// one. A live season whose rollover halted for want of a policy runs again.
fn approve_tx(c: pg.Conn, a: ApproveArg) -> result[service.PolicyView, str] {
    let d = until_of(time.mono() + a.timeout);
    let orr: result[[CountRow], str] = zokor.conn_query_all(c, is_operator_sql(), [pg.arg_text(a.operator)], d);
    guard let ops = orr else let e = err_of(orr) {
        return err(e);
    }
    if ops[0].n == 0 {
        return err("operator " + a.operator + " has no admin role");
    }
    let sr: result[[StatusRow], str] = zokor.conn_query_all(c,
        "select status from issuance_policies where id = $1::uuid for update", [pg.arg_text(a.policy_id)], d);
    guard let st = sr else let e = err_of(sr) {
        return err(e);
    }
    if len(st) == 0 {
        return err("no policy " + a.policy_id);
    }
    if st[0].status != "PROPOSED" {
        return err("policy " + a.policy_id + " is " + st[0].status);
    }
    let ir = exec(c, "insert into issuance_policy_approvals (policy_id, operator_id) values ($1::uuid, $2::uuid) " +
                     "on conflict do nothing", [pg.arg_text(a.policy_id), pg.arg_text(a.operator)], d);
    guard let _i = ir else let e = err_of(ir) {
        return err(e);
    }
    let ar = exec(c, "insert into audit_events (actor_id, action, target_type, target_id, detail) " +
                     "values ($1::uuid, 'issuance_policy.approve', 'issuance_policy', $2, '{}'::jsonb)",
                  [pg.arg_text(a.operator), pg.arg_text(a.policy_id)], d);
    guard let _a = ar else let e = err_of(ar) {
        return err(e);
    }
    let cr: result[[CountRow], str] = zokor.conn_query_all(c,
        "select count(*)::bigint as n from issuance_policy_approvals where policy_id = $1::uuid", [pg.arg_text(a.policy_id)], d);
    guard let counts = cr else let e = err_of(cr) {
        return err(e);
    }
    if counts[0].n >= 2 {
        let none_args: [pg.Arg] = [];
        let rr = exec(c, "update issuance_policies set status = 'REVOKED', revoked_at = now() where status = 'APPROVED'",
                      none_args, d);
        guard let _r = rr else let e = err_of(rr) {
            return err(e);
        }
        let ur = exec(c, "update issuance_policies set status = 'APPROVED', approved_at = now() where id = $1::uuid",
                      [pg.arg_text(a.policy_id)], d);
        guard let _u = ur else let e = err_of(ur) {
            return err(e);
        }
        let gr = exec(c,
            "update grant_runs g set finished_at = null, halted_reason = null, last_account_id = null " +
            "from seasons s where s.id = g.season_id and s.status = 'ACTIVE' and g.halted_reason is not null",
            none_args, d);
        guard let _g = gr else let e = err_of(gr) {
            return err(e);
        }
    }
    let vr: result[[PolicyViewRow], str] = zokor.conn_query_all(c,
        "select p.id::text as id, p.amount, p.season_cap, p.status, p.proposed_by::text as proposed_by, " +
        "coalesce((select string_agg(a.operator_id::text, ',' order by a.approved_at) " +
        "from issuance_policy_approvals a where a.policy_id = p.id), '') as approvals from issuance_policies p " +
        "where p.id = $1::uuid", [pg.arg_text(a.policy_id)], d);
    guard let views = vr else let e = err_of(vr) {
        return err(e);
    }
    return ok(to_view(views[0]));
}

fn st_policy_approve(p: Postgres, policy_id: str, operator: str) -> result[service.PolicyView, str] {
    return zokor.transaction(p.pool, ApproveArg { policy_id: policy_id, operator: operator, timeout: p.timeout },
                             approve_tx, until_of(time.mono() + p.timeout));
}

fn st_policies(p: Postgres) -> result[[service.PolicyView], str] {
    let none_args: [pg.Arg] = [];
    let r: result[[PolicyViewRow], str] = zokor.query_all(p.pool,
        "select p.id::text as id, p.amount, p.season_cap, p.status, p.proposed_by::text as proposed_by, " +
        "coalesce((select string_agg(a.operator_id::text, ',' order by a.approved_at) " +
        "from issuance_policy_approvals a where a.policy_id = p.id), '') as approvals from issuance_policies p " +
        "order by p.created_at desc", none_args, deadline(p));
    guard let rows = r else let e = err_of(r) {
        return err(e);
    }
    let out: [service.PolicyView] = [];
    for row in rows {
        push(out, to_view(row));
    }
    return ok(out);
}

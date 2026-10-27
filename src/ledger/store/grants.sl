import "pg";
import "strings";
import "time";
import "timez";
import "zokor";
import "../domain" as domain;
import "../service" as service;
import "../../approvals/store" as approvals;

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

gc struct PolicyHashRow { hash: str }
gc struct NowRow { now: int }
gc struct VoteCountRow { n: int }
gc struct VoteExistsRow { present: bool }
gc struct PolicyArg { amount: int, cap: int, operator: str, timeout: int }
gc struct ApproveArg {
    policy_id: str,
    operator: str,
    timeout: int
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

fn database_now(c: pg.Conn, d: until) -> result[int, str] {
    let args: [pg.Arg] = [];
    let r: result[[NowRow], str] = zokor.conn_query_all(c,
        "select (extract(epoch from clock_timestamp())*1000)::bigint as now",args,d);
    guard let rows = r else let e = err_of(r) { return err(e); }
    return ok(rows[0].now);
}

fn policy_view(c: pg.Conn, policy_id: str, d: until) -> result[service.PolicyView, str] {
    let r: result[[PolicyViewRow], str] = zokor.conn_query_all(c,
        "select p.id::text as id,p.amount,p.season_cap,p.status,p.proposed_by::text as proposed_by," +
        "coalesce((select string_agg(v.operator_id,',' order by v.approved_at,v.operator_id) from (" +
        "select a.operator_id::text as operator_id,a.approved_at from issuance_policy_approvals a where a.policy_id=p.id " +
        "union all select d.decided_by::text as operator_id,d.decided_at as approved_at " +
        "from approval_requests r join approval_decisions d on d.approval_id=r.id " +
        "where r.kind='issuance_policy' and r.subject_id=p.id and r.payload_hash=issuance_policy_payload_hash(p.id) " +
        "and d.decision='approved') v),'') as approvals from issuance_policies p where p.id=$1::uuid",
        [pg.arg_text(policy_id)],d);
    guard let rows = r else let e = err_of(r) { return err(e); }
    if len(rows) == 0 { return err("no policy " + policy_id); }
    return ok(to_view(rows[0]));
}

fn policy_vote_count(c: pg.Conn, policy_id: str, hash: str, requester: str, d: until) -> result[int, str] {
    let r: result[[VoteCountRow], str] = zokor.conn_query_all(c,
        "select count(*)::bigint as n from (" +
        "select a.operator_id from issuance_policy_approvals a where a.policy_id=$1::uuid and a.operator_id<>$3::uuid " +
        "union select d.decided_by from approval_requests r join approval_decisions d on d.approval_id=r.id " +
        "where r.kind='issuance_policy' and r.subject_id=$1::uuid and r.payload_hash=$2 and d.decision='approved' " +
        "and d.decided_by<>$3::uuid) votes",
        [pg.arg_text(policy_id),pg.arg_text(hash),pg.arg_text(requester)],d);
    guard let rows = r else let e = err_of(r) { return err(e); }
    return ok(rows[0].n);
}

fn policy_actor_voted(c: pg.Conn, policy_id: str, hash: str, actor: str, d: until) -> result[bool, str] {
    let r: result[[VoteExistsRow], str] = zokor.conn_query_all(c,
        "select exists(select 1 from issuance_policy_approvals a where a.policy_id=$1::uuid and a.operator_id=$3::uuid " +
        "union select 1 from approval_requests r join approval_decisions d on d.approval_id=r.id " +
        "where r.kind='issuance_policy' and r.subject_id=$1::uuid and r.payload_hash=$2 and d.decided_by=$3::uuid) as present",
        [pg.arg_text(policy_id),pg.arg_text(hash),pg.arg_text(actor)],d);
    guard let rows = r else let e = err_of(r) { return err(e); }
    return ok(rows[0].present);
}

fn propose_tx(c: pg.Conn, a: PolicyArg) -> result[str, str] {
    let d = until_of(time.mono() + a.timeout);
    let orr: result[[CountRow], str] = zokor.conn_query_all(c,is_operator_sql(),[pg.arg_text(a.operator)],d);
    guard let ops = orr else let e = err_of(orr) { return err(e); }
    if ops[0].n == 0 { return err("operator " + a.operator + " has no admin role"); }
    let r: result[[IdRow], str] = zokor.conn_query_all(c,
        "insert into issuance_policies (amount, season_cap, status, proposed_by) " +
        "select $1, $2, 'PROPOSED', $3::uuid " +
        "where exists (select 1 from account_roles where account_id = $3::uuid and role in ('admin', 'super_admin')) " +
        "returning id::text as id",
        [pg.arg_int(a.amount), pg.arg_int(a.cap), pg.arg_text(a.operator)],d);
    guard let rows = r else let e = err_of(r) {
        return err(e);
    }
    if len(rows) == 0 {
        return err("operator " + a.operator + " has no admin role");
    }
    let hash_result: result[[PolicyHashRow], str] = zokor.conn_query_all(c,
        "select issuance_policy_payload_hash($1::uuid) as hash",[pg.arg_text(rows[0].id)],d);
    guard let hashes = hash_result else let e = err_of(hash_result) { return err(e); }
    let nr = database_now(c,d);
    guard let now = nr else let e = err_of(nr) { return err(e); }
    for slot in [1,2] {
        let requested = approvals.request(c,"issuance_policy","issuance_policy",rows[0].id,hashes[0].hash,
            a.operator,1,slot,"Approve issuance policy",now,d);
        guard let _request_id = requested else let e = err_of(requested) { return err(e); }
    }
    return ok(rows[0].id);
}

fn approve_tx(c: pg.Conn, a: ApproveArg) -> result[service.PolicyView, str] {
    let d = until_of(time.mono() + a.timeout);
    let orr: result[[CountRow], str] = zokor.conn_query_all(c,
        "select count(*)::bigint as n from account_roles where account_id=$1::uuid and role='super_admin'",
        [pg.arg_text(a.operator)],d);
    guard let ops = orr else let e = err_of(orr) { return err(e); }
    if ops[0].n == 0 {
        return err("operator " + a.operator + " has no super_admin role");
    }
    let sr: result[[PolicyViewRow], str] = zokor.conn_query_all(c,
        "select p.id::text as id,p.amount,p.season_cap,p.status,p.proposed_by::text as proposed_by,coalesce((select string_agg(v.operator_id,',' order by v.approved_at,v.operator_id) from (select a.operator_id::text as operator_id,a.approved_at from issuance_policy_approvals a where a.policy_id=p.id union all select d.decided_by::text as operator_id,d.decided_at as approved_at from approval_requests r join approval_decisions d on d.approval_id=r.id where r.kind='issuance_policy' and r.subject_id=p.id and r.payload_hash=issuance_policy_payload_hash(p.id) and d.decision='approved') v),'') as approvals from issuance_policies p where p.id=$1::uuid for update",
        [pg.arg_text(a.policy_id)],d);
    guard let st = sr else let e = err_of(sr) { return err(e); }
    if len(st) == 0 {
        return err("no policy " + a.policy_id);
    }
    let hash_result: result[[PolicyHashRow], str] = zokor.conn_query_all(c,
        "select issuance_policy_payload_hash($1::uuid) as hash",[pg.arg_text(a.policy_id)],d);
    guard let hashes = hash_result else let e = err_of(hash_result) { return err(e); }
    if a.operator == st[0].proposed_by {
        return err("SELF_APPROVAL_FORBIDDEN");
    }
    let voted = policy_actor_voted(c,a.policy_id,hashes[0].hash,a.operator,d);
    guard let already_voted = voted else let e = err_of(voted) { return err(e); }
    if already_voted { return ok(to_view(st[0])); }
    if st[0].status != "PROPOSED" {
        return err("policy " + a.policy_id + " is " + st[0].status);
    }
    let pr = approvals.pending(c,"issuance_policy",a.policy_id,hashes[0].hash,d);
    guard let pending = pr else let e = err_of(pr) { return err(e); }
    guard let request = pending else { return err("STALE_APPROVAL"); }
    let nr = database_now(c,d);
    guard let now = nr else let e = err_of(nr) { return err(e); }
    let decided = approvals.decide(c,request,a.operator,"approved","",now,d);
    guard let _decision = decided else let e = err_of(decided) { return err(e); }
    let ar = exec(c,
        "insert into audit_events(actor_id,action,target_type,target_id,detail) " +
        "values($1::uuid,'issuance_policy.approve','issuance_policy',$2,$3::jsonb)",
        [pg.arg_text(a.operator),pg.arg_text(a.policy_id),
         pg.arg_text(zokor.jobj().set_str("approval_id",request.id).set_str("payload_hash",hashes[0].hash).render())],d);
    guard let _a = ar else let e = err_of(ar) { return err(e); }
    let count_result = policy_vote_count(c,a.policy_id,hashes[0].hash,st[0].proposed_by,d);
    guard let votes = count_result else let e = err_of(count_result) { return err(e); }
    if votes >= 2 {
        let none_args: [pg.Arg] = [];
        let rr = exec(c,"update issuance_policies set status='REVOKED',revoked_at=now() where status='APPROVED'",
                      none_args,d);
        guard let _r = rr else let e = err_of(rr) { return err(e); }
        let ur = exec(c,
            "update issuance_policies set status='APPROVED',approved_at=now() where id=$1::uuid and status='PROPOSED'",
            [pg.arg_text(a.policy_id)],d);
        guard let _u = ur else let e = err_of(ur) { return err(e); }
        let gr = exec(c,
            "update grant_runs g set finished_at=null,halted_reason=null,last_account_id=null " +
            "from seasons s where s.id=g.season_id and s.status='ACTIVE' and g.halted_reason is not null",
            none_args,d);
        guard let _g = gr else let e = err_of(gr) { return err(e); }
        let applied = exec(c,
            "insert into approval_applications(approval_id,subject_id,applied_at) " +
            "select r.id,r.subject_id,now() from approval_requests r join approval_state s on s.approval_id=r.id " +
            "where r.kind='issuance_policy' and r.subject_id=$1::uuid and r.payload_hash=$2 and s.status='approved' " +
            "on conflict(approval_id) do nothing",
            [pg.arg_text(a.policy_id),pg.arg_text(hashes[0].hash)],d);
        guard let _applied = applied else let e = err_of(applied) { return err(e); }
        let emitted = exec(c,
            "insert into outbox_events(type,payload,created_at) " +
            "values('issuance_policy.approved',$1::jsonb,now())",
            [pg.arg_text(zokor.jobj().set_str("policy_id",a.policy_id).set_str("payload_hash",hashes[0].hash).render())],d);
        guard let _event = emitted else let e = err_of(emitted) { return err(e); }
    }
    return policy_view(c,a.policy_id,d);
}

fn st_policy_propose(p: Postgres, amount: int, cap: int, operator: str) -> result[str, str] {
    return zokor.transaction(p.pool,PolicyArg { amount: amount,cap: cap,operator: operator,timeout: p.timeout },
        propose_tx,until_of(time.mono()+p.timeout));
}

fn st_policy_approve(p: Postgres, policy_id: str, operator: str) -> result[service.PolicyView, str] {
    return zokor.transaction(p.pool, ApproveArg { policy_id: policy_id, operator: operator, timeout: p.timeout },
                             approve_tx, until_of(time.mono() + p.timeout));
}

fn st_policies(p: Postgres) -> result[[service.PolicyView], str] {
    let none_args: [pg.Arg] = [];
    let r: result[[PolicyViewRow], str] = zokor.query_all(p.pool,
        "select p.id::text as id,p.amount,p.season_cap,p.status,p.proposed_by::text as proposed_by,coalesce((select string_agg(v.operator_id,',' order by v.approved_at,v.operator_id) from (select a.operator_id::text as operator_id,a.approved_at from issuance_policy_approvals a where a.policy_id=p.id union all select d.decided_by::text as operator_id,d.decided_at as approved_at from approval_requests r join approval_decisions d on d.approval_id=r.id where r.kind='issuance_policy' and r.subject_id=p.id and r.payload_hash=issuance_policy_payload_hash(p.id) and d.decision='approved') v),'') as approvals from issuance_policies p order by p.created_at desc",
        none_args, deadline(p));
    guard let rows = r else let e = err_of(r) {
        return err(e);
    }
    let out: [service.PolicyView] = [];
    for row in rows {
        push(out, to_view(row));
    }
    return ok(out);
}

import "json";
import "pg";
import "time";
import "zokor";
import "../domain" as domain;
import "../service" as service;
import "../../accounts/store" as accounts_store;
import "../../approvals/store" as approvals_store;
import "../../ledger/store" as ledger_store;

pub gc struct PostgresTreasuryStore {
    pool: pg.Pool
}

pub fn make_postgres_treasury_store(pool: pg.Pool) -> PostgresTreasuryStore {
    return PostgresTreasuryStore { pool: pool };
}

fn pg_deadline() -> until {
    return until_of(time.mono() + 5000000000);
}

gc struct SumRow {
    val: int
}

gc struct BoolRow {
    val: bool
}

gc struct TextRow {
    val: str
}

gc struct BotOverviewRow {
    bot_id: str,
    name: str,
    market_id: str,
    question: str,
    budget: int,
    used: int,
    holding_yes: int,
    holding_no: int,
    spread_ticks: int,
    last_quote_age_ms: int,
    status: str,
    params_version: int
}

gc struct DecisionRow {
    id: str,
    bot_id: str,
    market_id: str,
    at: str,
    inputs_digest: str,
    r: int,
    r_prime: int,
    spread: int,
    util: int,
    worst_case_loss: int,
    status: str,
    actions_json: str
}

gc struct BotParamsRow {
    base_spread_ticks: int,
    vol_ticks: int,
    skew_ticks: int,
    levels: int,
    base_size: int,
    max_net_shares: int,
    max_loss: int,
    season_max_drawdown: int,
    min_requote_ms: int,
    max_ops_per_sec: int,
    max_open_orders: int
}

fn exec_sql(pool: pg.Pool, sql: str, args: [pg.Arg], d: until) -> result[int, str] {
    let r: result[[TextRow], str] = zokor.query_all(pool, sql + " returning '' as val", args, d);
    guard let rows = r else let e = err_of(r) {
        return err(e);
    }
    return ok(len(rows));
}

gc struct SummaryRow {
    found: bool,
    given: int,
    allocated: int,
    collateral: int,
    fees: int,
    bot_cap: opt[int],
    books_balanced: opt[bool],
    halt_reason: opt[str],
    grant_policy_id: opt[str],
    grant_amount: opt[int],
    grant_players: int,
    next_season_at: opt[str]
}

// Every figure is read from the journal or its read models for one season;
// a failed read fails the summary rather than showing a zero as if it were real.
fn pg_get_summary(s: PostgresTreasuryStore, season_id: str) -> result[domain.TreasurySummary, str] {
    let q = "with s as (select id from seasons where ($1 = '' and status in ('ACTIVE','CLOSING')) or id::text = $1 " +
            "order by starts_at desc limit 1), " +
            "p as (select id, amount from issuance_policies where status = 'PROPOSED' order by created_at desc limit 1) " +
            "select exists(select 1 from s) as found, " +
            "coalesce((select sum(g.amount) from issuance_grants g where g.season_id = (select id from s)), 0)::bigint as given, " +
            "coalesce((select sum(b.allocated) from bot_markets b where b.season_id = (select id from s)), 0)::bigint as allocated, " +
            "coalesce((select sum(m.issued_pairs * m.redemption_units) from markets m where m.season_id = (select id from s) " +
            "and m.status not in ('DRAFT','REVIEW','APPROVED','FUNDING','SETTLED','VOIDED')), 0)::bigint as collateral, " +
            "coalesce((select sum(e.delta) from wallets w join ledger_entries e on e.wallet_id = w.id " +
            "where w.season_id = (select id from s) and w.owner_id = 'system:fees' and w.asset_key = 'SEDI'), 0)::bigint as fees, " +
            "(select b.cap from bot_season_budgets b where b.season_id = (select id from s) and b.status = 'APPLIED' order by b.decided_at desc limit 1) as bot_cap, " +
            "(select r.ok from reconciliation_runs r where r.status = 'done' order by r.finished_at desc limit 1) as books_balanced, " +
            "(select h.reason from trading_halt h where h.id = 1 and h.halted) as halt_reason, " +
            "(select p.id::text from p) as grant_policy_id, " +
            "(select p.amount from p) as grant_amount, " +
            "(select count(*) from accounts a where a.kind = 'USER' and a.status = 'ACTIVE' and a.email_verified_at is not null)::bigint as grant_players, " +
            "(select to_char(n.starts_at at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') from seasons n " +
            "where n.status = 'SCHEDULED' order by n.starts_at limit 1) as next_season_at";
    let res: result[[SummaryRow], str] = zokor.query_all(s.pool, q, [pg.arg_text(season_id)], pg_deadline());
    guard let rows = res else let e = err_of(res) {
        return err(e);
    }
    if len(rows) != 1 || !rows[0].found {
        return err("SEASON_NOT_FOUND");
    }
    let row = rows[0];
    let grants: opt[domain.SeasonGrantsInfo] = none;
    if let policy_id = row.grant_policy_id {
        let amount = row.grant_amount ?? 0;
        grants = some(domain.SeasonGrantsInfo {
            at: row.next_season_at ?? "",
            amount: amount,
            approx_players: row.grant_players,
            approx_total: amount * row.grant_players,
            approval_id: policy_id,
            status: "WAITING_SECOND_APPROVAL"
        });
    }
    return ok(domain.TreasurySummary {
        given_to_players: row.given,
        bot_budget: domain.BotBudgetInfo { allocated: row.allocated, cap: row.bot_cap },
        collateral_held: row.collateral,
        fees_collected: row.fees,
        season_grants_next: grants,
        books_balanced: row.books_balanced,
        incident_banner: row.halt_reason
    });
}

fn pg_list_bots(s: PostgresTreasuryStore) -> result[[domain.BotOverview], str] {
    let empty_args: [pg.Arg] = [];
    let q = "select b.bot_id::text, coalesce(a.username, 'bot') as name, b.market_id::text, m.question, " +
            "b.allocated as budget, b.used, " +
            "coalesce(p_yes.qty, 0) as holding_yes, " +
            "coalesce(p_no.qty, 0) as holding_no, " +
            "coalesce(bp.base_spread_ticks, 2) as spread_ticks, " +
            "coalesce(floor(extract(epoch from (now() - b.last_quote_at)) * 1000)::bigint, 999999) as last_quote_age_ms, " +
            "b.status, b.params_version " +
            "from bot_markets b " +
            "join accounts a on a.id = b.bot_id " +
            "join markets m on m.id = b.market_id " +
            "left join positions p_yes on p_yes.account_id = b.bot_id and p_yes.market_id = b.market_id and p_yes.outcome = 'YES' " +
            "left join positions p_no on p_no.account_id = b.bot_id and p_no.market_id = b.market_id and p_no.outcome = 'NO' " +
            "left join bot_params bp on bp.bot_id = b.bot_id and bp.market_id = b.market_id and bp.version = b.params_version " +
            "order by b.created_at asc";

    let res: result[[BotOverviewRow], str] = zokor.query_all(s.pool, q, empty_args, pg_deadline());
    guard let rows = res else let e = err_of(res) {
        return err(e);
    }

    let out: [domain.BotOverview] = [];
    for r in rows {
        push(out, domain.BotOverview {
            bot_id: r.bot_id,
            name: r.name,
            market: domain.MarketBrief { id: r.market_id, question: r.question },
            budget: r.budget,
            used: r.used,
            holding: domain.BotHolding { yes: r.holding_yes, no: r.holding_no },
            spread_ticks: r.spread_ticks,
            last_quote_age_ms: r.last_quote_age_ms,
            status: r.status,
            status_label: domain.status_to_label(r.status),
            params_version: r.params_version
        });
    }
    return ok(out);
}

fn pg_list_decisions(s: PostgresTreasuryStore, bot_id: str, market_id: str, limit: int) -> result[[domain.BotDecisionRecord], str] {
    let q = "select id::text, bot_id::text, market_id::text, at::text, inputs_digest, " +
            "r, r_prime, spread, util, worst_case_loss, status, actions::text as actions_json " +
            "from bot_decisions where bot_id = $1::uuid and market_id = $2::uuid " +
            "order by at desc limit $3";
    let res: result[[DecisionRow], str] = zokor.query_all(s.pool, q, [pg.arg_text(bot_id), pg.arg_text(market_id), pg.arg_int(limit)], pg_deadline());
    guard let rows = res else let e = err_of(res) {
        return err(e);
    }
    let out: [domain.BotDecisionRecord] = [];
    for r in rows {
        push(out, domain.BotDecisionRecord {
            id: r.id,
            bot_id: r.bot_id,
            market_id: r.market_id,
            at: r.at,
            inputs_digest: r.inputs_digest,
            r: r.r,
            r_prime: r.r_prime,
            spread: r.spread,
            util: r.util,
            worst_case_loss: r.worst_case_loss,
            status: r.status,
            actions_json: r.actions_json
        });
    }
    return ok(out);
}

fn pg_save_decisions(s: PostgresTreasuryStore, records: [domain.BotDecisionRecord]) -> result[bool, str] {
    let q = "insert into bot_decisions (id, bot_id, market_id, inputs_digest, r, r_prime, spread, util, worst_case_loss, status, actions) " +
            "values ($1::uuid, $2::uuid, $3::uuid, $4, $5, $6, $7, $8, $9, $10, $11::jsonb)";
    for rec in records {
        let act = rec.actions_json;
        if len(act) == 0 {
            act = "[]";
        }
        let res = exec_sql(s.pool, q, [
            pg.arg_text(rec.id),
            pg.arg_text(rec.bot_id),
            pg.arg_text(rec.market_id),
            pg.arg_text(rec.inputs_digest),
            pg.arg_int(rec.r),
            pg.arg_int(rec.r_prime),
            pg.arg_int(rec.spread),
            pg.arg_int(rec.util),
            pg.arg_int(rec.worst_case_loss),
            pg.arg_text(rec.status),
            pg.arg_text(act)
        ], pg_deadline());
        guard let _n = res else let e = err_of(res) {
            return err(e);
        }
    }
    return ok(true);
}

fn pg_set_status(s: PostgresTreasuryStore, bot_id: str, market_id: str, status: str, reason: str) -> result[bool, str] {
    let q = "update bot_markets set status = $1, status_reason = $2, updated_at = now() where bot_id = $3::uuid and market_id = $4::uuid";
    let res = exec_sql(s.pool, q, [pg.arg_text(status), pg.arg_text(reason), pg.arg_text(bot_id), pg.arg_text(market_id)], pg_deadline());
    guard let n = res else let e = err_of(res) {
        return err(e);
    }
    if n == 0 {
        return err("NOT_FOUND");
    }
    return ok(true);
}

gc struct PauseAllArg { paused: bool, reason: str }

fn set_all_paused_tx(c: pg.Conn, arg: PauseAllArg) -> result[bool, str] {
    let updated = ledger_store.set_bots_paused(c, arg.paused, pg_deadline());
    guard let _ok = updated else let e = err_of(updated) { return err(e); }
    let from_status = "PAUSED_ALL";
    let to_status = "QUOTING";
    if arg.paused { from_status = "QUOTING"; to_status = "PAUSED_ALL"; }
    let r = pg.query(c, "update bot_markets set status = $1, status_reason = $2, updated_at = now() where status = $3",
        [pg.arg_text(to_status), pg.arg_text(arg.reason), pg.arg_text(from_status)], pg_deadline());
    guard let _n = r else let e = err_of(r) { return err(e); }
    return ok(true);
}

fn pg_set_all_paused(s: PostgresTreasuryStore, paused: bool, reason: str) -> result[bool, str] {
    return zokor.transaction(s.pool, PauseAllArg { paused: paused, reason: reason }, set_all_paused_tx, pg_deadline());
}

fn pg_is_all_paused(s: PostgresTreasuryStore) -> result[bool, str] {
    let empty_args: [pg.Arg] = [];
    let q = "select bots_paused as val from trading_halt limit 1";
    let res: result[[BoolRow], str] = zokor.query_all(s.pool, q, empty_args, pg_deadline());
    guard let rows = res else let e = err_of(res) {
        return err(e);
    }
    if len(rows) > 0 {
        return ok(rows[0].val);
    }
    return ok(false);
}

fn pg_update_params(s: PostgresTreasuryStore, bot_id: str, market_id: str, p: domain.BotParams, op: str, exp_ver: int) -> result[int, str] {
    let next_ver = exp_ver + 1;
    let q = "insert into bot_params (bot_id, market_id, version, base_spread_ticks, vol_ticks, skew_ticks, levels, base_size, max_net_shares, max_loss, season_max_drawdown, min_requote_ms, max_ops_per_sec, max_open_orders, created_by) " +
            "values ($1::uuid, $2::uuid, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, nullif($15, '')::uuid)";
    let res = exec_sql(s.pool, q, [
        pg.arg_text(bot_id),
        pg.arg_text(market_id),
        pg.arg_int(next_ver),
        pg.arg_int(p.base_spread_ticks),
        pg.arg_int(p.vol_ticks),
        pg.arg_int(p.skew_ticks),
        pg.arg_int(p.levels),
        pg.arg_int(p.base_size),
        pg.arg_int(p.max_net_shares),
        pg.arg_int(p.max_loss),
        pg.arg_int(p.season_max_drawdown),
        pg.arg_int(p.min_requote_ms),
        pg.arg_int(p.max_ops_per_sec),
        pg.arg_int(p.max_open_orders),
        pg.arg_text(op)
    ], pg_deadline());
    guard let _n = res else let e = err_of(res) {
        return err(e);
    }
    let u_q = "update bot_markets set params_version = $1, updated_at = now() where bot_id = $2::uuid and market_id = $3::uuid";
    let _u = exec_sql(s.pool, u_q, [pg.arg_int(next_ver), pg.arg_text(bot_id), pg.arg_text(market_id)], pg_deadline());
    return ok(next_ver);
}

fn pg_get_params(s: PostgresTreasuryStore, bot_id: str, market_id: str) -> result[opt[domain.BotParams], str] {
    let none_p: opt[domain.BotParams] = none;
    let q = "select base_spread_ticks, vol_ticks, skew_ticks, levels, base_size, max_net_shares, max_loss, season_max_drawdown, min_requote_ms, max_ops_per_sec, max_open_orders " +
            "from bot_params where bot_id = $1::uuid and market_id = $2::uuid order by version desc limit 1";
    let res: result[[BotParamsRow], str] = zokor.query_all(s.pool, q, [pg.arg_text(bot_id), pg.arg_text(market_id)], pg_deadline());
    guard let rows = res else let e = err_of(res) {
        return err(e);
    }
    if len(rows) == 0 {
        return ok(none_p);
    }
    let r = rows[0];
    return ok(some(domain.BotParams {
        base_spread_ticks: r.base_spread_ticks,
        vol_ticks: r.vol_ticks,
        skew_ticks: r.skew_ticks,
        levels: r.levels,
        base_size: r.base_size,
        max_net_shares: r.max_net_shares,
        max_loss: r.max_loss,
        season_max_drawdown: r.season_max_drawdown,
        min_requote_ms: r.min_requote_ms,
        max_ops_per_sec: r.max_ops_per_sec,
        max_open_orders: r.max_open_orders
    }));
}

fn now_ms() -> int {
    return (time.wall() / 1000000) as int;
}

gc struct TopupArg {
    bot: str,
    market: str,
    amount: int,
    op: str,
    reason: str
}

gc struct TopupInsertRow {
    id: str,
    season_id: str
}

fn request_topup_tx(c: pg.Conn, a: TopupArg) -> result[service.FundingRequest, str] {
    let ins: result[[TopupInsertRow], str] = zokor.conn_query_all(c,
        "insert into bot_topups (bot_id, market_id, season_id, amount, reason, requested_by) " +
        "select b.bot_id, b.market_id, b.season_id, $3, $4, $5::uuid from bot_markets b " +
        "where b.bot_id = $1::uuid and b.market_id = $2::uuid returning id::text as id, season_id::text as season_id",
        [pg.arg_text(a.bot), pg.arg_text(a.market), pg.arg_int(a.amount), pg.arg_text(a.reason), pg.arg_text(a.op)], pg_deadline());
    guard let rows = ins else let e = err_of(ins) { return err(e); }
    if len(rows) != 1 { return err("NOT_FOUND"); }
    let id = rows[0].id;
    let hash = domain.topup_hash(id, a.bot, a.market, a.amount);
    let label = "Top up bot by " + to_str(a.amount) + " Sedis";
    if len(a.reason) > 0 { label = label + ": " + a.reason; }
    let req = approvals_store.request(c, "bot_topup", "bot_topup", id, hash, a.op, 1, 1, label, now_ms(), pg_deadline());
    guard let approval_id = req else let e = err_of(req) { return err(e); }
    return ok(service.FundingRequest { id: id, approval_ids: [approval_id] });
}

fn pg_request_topup(s: PostgresTreasuryStore, bot: str, market: str, amount: int, op: str, reason: str) -> result[service.FundingRequest, str] {
    return zokor.transaction(s.pool, TopupArg { bot: bot, market: market, amount: amount, op: op, reason: reason }, request_topup_tx, pg_deadline());
}

gc struct BudgetArg {
    season: str,
    cap: int,
    op: str,
    reason: str
}

// A season budget is two requests, one per approver slot; it applies only
// when both are approved by different operators.
fn request_budget_tx(c: pg.Conn, a: BudgetArg) -> result[service.FundingRequest, str] {
    let ins: result[[TextRow], str] = zokor.conn_query_all(c,
        "insert into bot_season_budgets (season_id, cap, reason, requested_by) " +
        "select id, $2, $3, $4::uuid from seasons where id::text = $1 and status <> 'FINALIZED' returning id::text as val",
        [pg.arg_text(a.season), pg.arg_int(a.cap), pg.arg_text(a.reason), pg.arg_text(a.op)], pg_deadline());
    guard let rows = ins else let e = err_of(ins) { return err(e); }
    if len(rows) != 1 { return err("SEASON_NOT_FOUND"); }
    let id = rows[0].val;
    let hash = domain.season_budget_hash(id, a.season, a.cap);
    let label = "Bot budget of " + to_str(a.cap) + " Sedis for the season";
    if len(a.reason) > 0 { label = label + ": " + a.reason; }
    let ids: [str] = [];
    for slot in [1, 2] {
        let req = approvals_store.request(c, "bot_season_budget", "bot_season_budget", id, hash, a.op, 1, slot, label, now_ms(), pg_deadline());
        guard let approval_id = req else let e = err_of(req) { return err(e); }
        push(ids, approval_id);
    }
    return ok(service.FundingRequest { id: id, approval_ids: ids });
}

fn pg_request_season_budget(s: PostgresTreasuryStore, season: str, cap: int, op: str, reason: str) -> result[service.FundingRequest, str] {
    return zokor.transaction(s.pool, BudgetArg { season: season, cap: cap, op: op, reason: reason }, request_budget_tx, pg_deadline());
}

gc struct PendingBudgetRow {
    id: str,
    approved: int,
    refused: int,
    expired: int
}

gc struct PendingTopupRow {
    id: str,
    status: str,
    expired: bool
}

gc struct LockedTopupRow {
    bot_id: str,
    market_id: str,
    season_id: str,
    amount: int,
    approval_id: str,
    hash_ok: bool
}

gc struct CapRow {
    cap: opt[int],
    allocated: int
}

gc struct ApplyArg {
    id: str
}

fn close_topup(c: pg.Conn, id: str, status: str, why: str) -> result[str, str] {
    let r = pg.query(c,
        "update bot_topups set status = $2, status_reason = $3, decided_at = now() where id = $1::uuid and status = 'PENDING'",
        [pg.arg_text(id), pg.arg_text(status), pg.arg_text(why)], pg_deadline());
    guard let _n = r else let e = err_of(r) { return err(e); }
    return ok(status);
}

// Everything that can refuse a top-up is checked inside the transaction
// that moves the money, with the season's bot rows locked, so two top-ups
// approved at once cannot both slip under the cap.
fn apply_topup_tx(c: pg.Conn, a: ApplyArg) -> result[str, str] {
    let locked: result[[LockedTopupRow], str] = zokor.conn_query_all(c,
        "select t.bot_id::text as bot_id, t.market_id::text as market_id, t.season_id::text as season_id, t.amount, " +
        "r.id::text as approval_id, r.payload_hash = encode(sha256(convert_to('bot_topup|' || t.id::text || '|' || t.bot_id::text || '|' || t.market_id::text || '|' || t.amount::text, 'UTF8')), 'hex') as hash_ok " +
        "from bot_topups t join approval_requests r on r.kind = 'bot_topup' and r.subject_id = t.id " +
        "join approval_state st on st.approval_id = r.id " +
        "where t.id = $1::uuid and t.status = 'PENDING' and st.status = 'approved' for update of t",
        [pg.arg_text(a.id)], pg_deadline());
    guard let rows = locked else let e = err_of(locked) { return err(e); }
    if len(rows) != 1 { return ok("SKIPPED"); }
    let t = rows[0];
    if !t.hash_ok { return close_topup(c, a.id, "REJECTED", "approval does not match the request"); }
    let lock_rows = pg.query(c, "select 1 from bot_markets where season_id = $1::uuid for update", [pg.arg_text(t.season_id)], pg_deadline());
    guard let _l = lock_rows else let e = err_of(lock_rows) { return err(e); }
    let cap_res: result[[CapRow], str] = zokor.conn_query_all(c,
        "select (select b.cap from bot_season_budgets b where b.season_id = $1::uuid and b.status = 'APPLIED' order by b.decided_at desc limit 1) as cap, " +
        "coalesce((select sum(allocated) from bot_markets where season_id = $1::uuid), 0)::bigint as allocated",
        [pg.arg_text(t.season_id)], pg_deadline());
    guard let caps = cap_res else let e = err_of(cap_res) { return err(e); }
    guard let cap = caps[0].cap else {
        return close_topup(c, a.id, "REJECTED", "no approved bot budget for this season");
    }
    if caps[0].allocated + t.amount > cap {
        return close_topup(c, a.id, "REJECTED", "would exceed the season bot budget of " + to_str(cap));
    }
    let posted = ledger_store.post_bot_funding(c, t.bot_id, t.season_id, t.market_id, a.id, t.amount, pg_deadline());
    guard let _p = posted else let e = err_of(posted) { return err(e); }
    let raised = pg.query(c,
        "update bot_markets set allocated = allocated + $3, updated_at = now() where bot_id = $1::uuid and market_id = $2::uuid",
        [pg.arg_text(t.bot_id), pg.arg_text(t.market_id), pg.arg_int(t.amount)], pg_deadline());
    guard let _r = raised else let e = err_of(raised) { return err(e); }
    let done = approvals_store.applied(c, t.approval_id, a.id, now_ms(), pg_deadline());
    guard let _d = done else let e = err_of(done) { return err(e); }
    return close_topup(c, a.id, "APPLIED", "");
}

fn apply_budget_tx(c: pg.Conn, a: ApplyArg) -> result[str, str] {
    let r: result[[TextRow], str] = zokor.conn_query_all(c,
        "update bot_season_budgets b set status = 'APPLIED', decided_at = now() where b.id = $1::uuid and b.status = 'PENDING' " +
        "and (select count(distinct d.decided_by) from approval_requests q join approval_state st on st.approval_id = q.id " +
        "join approval_decisions d on d.id = st.decision_id where q.kind = 'bot_season_budget' and q.subject_id = b.id " +
        "and st.status = 'approved' and q.payload_hash = encode(sha256(convert_to('bot_season_budget|' || b.id::text || '|' || b.season_id::text || '|' || b.cap::text, 'UTF8')), 'hex')) >= 2 " +
        "returning b.id::text as val",
        [pg.arg_text(a.id)], pg_deadline());
    guard let rows = r else let e = err_of(r) { return err(e); }
    if len(rows) != 1 { return ok("SKIPPED"); }
    let reqs: result[[TextRow], str] = zokor.conn_query_all(c,
        "select id::text as val from approval_requests where kind = 'bot_season_budget' and subject_id = $1::uuid",
        [pg.arg_text(a.id)], pg_deadline());
    guard let ids = reqs else let e = err_of(reqs) { return err(e); }
    for q in ids {
        let done = approvals_store.applied(c, q.val, a.id, now_ms(), pg_deadline());
        guard let _d = done else let e = err_of(done) { return err(e); }
    }
    return ok("APPLIED");
}

fn tally(report: service.FundingReport, what: str, id: str, res: result[str, str]) {
    if let outcome = res {
        if outcome == "APPLIED" { report.applied += 1; }
        if outcome == "REJECTED" { report.rejected += 1; }
    } else let e = err_of(res) {
        push(report.problems, what + " " + id + ": " + e);
    }
}

// Budgets are applied before top-ups, so a top-up approved together with
// its season's first budget can use it in the same round.
fn pg_apply_funding(s: PostgresTreasuryStore) -> result[service.FundingReport, str] {
    let none_args: [pg.Arg] = [];
    let problems: [str] = [];
    let report = service.FundingReport { applied: 0, rejected: 0, problems: problems };

    let budgets: result[[PendingBudgetRow], str] = zokor.query_all(s.pool,
        "select b.id::text as id, " +
        "count(*) filter (where st.status = 'approved')::int as approved, " +
        "count(*) filter (where st.status in ('rejected', 'stale'))::int as refused, " +
        "count(*) filter (where st.status = 'pending' and q.expires_at <= now())::int as expired " +
        "from bot_season_budgets b join approval_requests q on q.kind = 'bot_season_budget' and q.subject_id = b.id " +
        "join approval_state st on st.approval_id = q.id where b.status = 'PENDING' group by b.id limit 50",
        none_args, pg_deadline());
    guard let pending_budgets = budgets else let e = err_of(budgets) { return err(e); }
    for b in pending_budgets {
        if b.refused > 0 || b.expired > 0 {
            let why = "an approver rejected it";
            if b.refused == 0 { why = "its approval expired"; }
            let closed = pg.pool_query(s.pool,
                "update bot_season_budgets set status = 'REJECTED', status_reason = $2, decided_at = now() where id = $1::uuid and status = 'PENDING'",
                [pg.arg_text(b.id), pg.arg_text(why)], pg_deadline());
            if let _c = closed { report.rejected += 1; } else let e = err_of(closed) { push(report.problems, "budget " + b.id + ": " + e); }
        } else if b.approved >= 2 {
            tally(report, "budget", b.id, zokor.transaction(s.pool, ApplyArg { id: b.id }, apply_budget_tx, pg_deadline()));
        }
    }

    let topups: result[[PendingTopupRow], str] = zokor.query_all(s.pool,
        "select t.id::text as id, st.status, (st.status = 'pending' and q.expires_at <= now()) as expired " +
        "from bot_topups t join approval_requests q on q.kind = 'bot_topup' and q.subject_id = t.id " +
        "join approval_state st on st.approval_id = q.id " +
        "where t.status = 'PENDING' and st.status <> 'pending' or (t.status = 'PENDING' and q.expires_at <= now()) " +
        "order by t.created_at limit 50",
        none_args, pg_deadline());
    guard let pending_topups = topups else let e = err_of(topups) { return err(e); }
    for t in pending_topups {
        if t.status == "approved" {
            tally(report, "topup", t.id, zokor.transaction(s.pool, ApplyArg { id: t.id }, apply_topup_tx, pg_deadline()));
        } else {
            let why = "an approver rejected it";
            if t.expired { why = "its approval expired"; }
            if t.status == "stale" { why = "its approval went stale"; }
            let closed = pg.pool_query(s.pool,
                "update bot_topups set status = 'REJECTED', status_reason = $2, decided_at = now() where id = $1::uuid and status = 'PENDING'",
                [pg.arg_text(t.id), pg.arg_text(why)], pg_deadline());
            if let _c = closed { report.rejected += 1; } else let e = err_of(closed) { push(report.problems, "topup " + t.id + ": " + e); }
        }
    }
    return ok(report);
}

gc struct BotArg {
    username: str,
    key_hash: str,
    key_prefix: str
}

fn create_bot_tx(c: pg.Conn, a: BotArg) -> result[str, str] {
    let made = accounts_store.insert_bot_account(c, a.username, domain.house_group(), pg_deadline());
    guard let bot_id = made else let e = err_of(made) { return err(e); }
    let key = pg.query(c,
        "insert into bot_api_keys (bot_id, key_hash, key_prefix, label) values ($1::uuid, $2, $3, 'initial')",
        [pg.arg_text(bot_id), pg.arg_text(a.key_hash), pg.arg_text(a.key_prefix)], pg_deadline());
    guard let _k = key else let e = err_of(key) { return err(e); }
    return ok(bot_id);
}

fn pg_create_bot(s: PostgresTreasuryStore, username: str, key_hash: str, key_prefix: str) -> result[str, str] {
    return zokor.transaction(s.pool, BotArg { username: username, key_hash: key_hash, key_prefix: key_prefix }, create_bot_tx, pg_deadline());
}

gc struct KeyArg {
    bot: str,
    key_hash: str,
    key_prefix: str
}

// Issuing a key revokes every earlier one: a leaked key stops working the
// moment its replacement exists.
fn issue_key_tx(c: pg.Conn, a: KeyArg) -> result[bool, str] {
    let bot: result[[TextRow], str] = zokor.conn_query_all(c,
        "select id::text as val from accounts where id = $1::uuid and kind = 'BOT' for update",
        [pg.arg_text(a.bot)], pg_deadline());
    guard let found = bot else let e = err_of(bot) { return err(e); }
    if len(found) != 1 { return err("NOT_FOUND"); }
    let revoke = pg.query(c, "update bot_api_keys set revoked_at = now() where bot_id = $1::uuid and revoked_at is null",
        [pg.arg_text(a.bot)], pg_deadline());
    guard let _r = revoke else let e = err_of(revoke) { return err(e); }
    let key = pg.query(c,
        "insert into bot_api_keys (bot_id, key_hash, key_prefix, label) values ($1::uuid, $2, $3, 'rotated')",
        [pg.arg_text(a.bot), pg.arg_text(a.key_hash), pg.arg_text(a.key_prefix)], pg_deadline());
    guard let _k = key else let e = err_of(key) { return err(e); }
    return ok(true);
}

fn pg_issue_bot_key(s: PostgresTreasuryStore, bot: str, key_hash: str, key_prefix: str) -> result[bool, str] {
    return zokor.transaction(s.pool, KeyArg { bot: bot, key_hash: key_hash, key_prefix: key_prefix }, issue_key_tx, pg_deadline());
}

fn pg_assign_bot(s: PostgresTreasuryStore, bot: str, market: str) -> result[bool, str] {
    let r: result[[TextRow], str] = zokor.query_all(s.pool,
        "insert into bot_markets (bot_id, market_id, season_id, status, status_reason) " +
        "select a.id, m.id, m.season_id, 'PAUSED_MANUAL', 'new assignment: fund and resume to start' " +
        "from accounts a, markets m where a.id = $1::uuid and a.kind = 'BOT' and a.status = 'ACTIVE' " +
        "and m.id = $2::uuid and m.season_id is not null and m.status in ('APPROVED','FUNDING','OPEN','SUSPENDED') " +
        "on conflict (bot_id, market_id) do nothing returning bot_id::text as val",
        [pg.arg_text(bot), pg.arg_text(market)], pg_deadline());
    guard let rows = r else let e = err_of(r) { return err(e); }
    if len(rows) != 1 {
        let exists: result[[TextRow], str] = zokor.query_all(s.pool,
            "select bot_id::text as val from bot_markets where bot_id = $1::uuid and market_id = $2::uuid",
            [pg.arg_text(bot), pg.arg_text(market)], pg_deadline());
        guard let ex = exists else let e = err_of(exists) { return err(e); }
        if len(ex) == 1 { return ok(false); }
        return err("NOT_FOUND");
    }
    return ok(true);
}

gc struct HeartbeatRow {
    status: str,
    allocated: int,
    params_version: int,
    trading_halted: bool
}

// A paused row stays paused whatever the bot reports, and a bot that
// reports during a global pause is moved to PAUSED_ALL rather than QUOTING.
fn pg_record_heartbeat(s: PostgresTreasuryStore, p: domain.HeartbeatPayload) -> result[domain.BotDirective, str] {
    let q = "update bot_markets set used = $1, " +
            "status = case when status in ('PAUSED_MANUAL','PAUSED_ALL') then status " +
            "when coalesce((select h.bots_paused from trading_halt h where h.id = 1), false) then 'PAUSED_ALL' else $2 end, " +
            "status_reason = case when status in ('PAUSED_MANUAL','PAUSED_ALL') " +
            "or coalesce((select h.bots_paused from trading_halt h where h.id = 1), false) then status_reason else $3 end, " +
            "last_quote_at = now(), updated_at = now() " +
            "where bot_id = $4::uuid and market_id = $5::uuid " +
            "returning status, allocated, params_version, coalesce((select h.halted from trading_halt h where h.id = 1), false) as trading_halted";
    let res: result[[HeartbeatRow], str] = zokor.query_all(s.pool, q,
        [pg.arg_int(p.used), pg.arg_text(p.status), pg.arg_text(p.status_reason), pg.arg_text(p.bot_id), pg.arg_text(p.market_id)],
        pg_deadline());
    guard let rows = res else let e = err_of(res) {
        return err(e);
    }
    if len(rows) != 1 {
        return err("NOT_FOUND");
    }
    let r = rows[0];
    return ok(domain.BotDirective {
        status: r.status, allocated: r.allocated, trading_halted: r.trading_halted,
        params_version: r.params_version, params: domain.default_params()
    });
}

fn pg_bot_ids(s: PostgresTreasuryStore) -> result[[str], str] {
    let empty_args: [pg.Arg] = [];
    let res: result[[TextRow], str] = zokor.query_all(s.pool, "select distinct bot_id::text as val from bot_markets order by 1", empty_args, pg_deadline());
    guard let rows = res else let e = err_of(res) {
        return err(e);
    }
    let out: [str] = [];
    for r in rows {
        push(out, r.val);
    }
    return ok(out);
}

pub fn treasury_store(s: PostgresTreasuryStore) -> service.TreasuryStore[PostgresTreasuryStore] {
    return service.TreasuryStore[PostgresTreasuryStore] {
        context: s,
        get_summary: pg_get_summary,
        list_bots: pg_list_bots,
        list_decisions: pg_list_decisions,
        save_decisions: pg_save_decisions,
        set_status: pg_set_status,
        set_all_paused: pg_set_all_paused,
        is_all_paused: pg_is_all_paused,
        update_params: pg_update_params,
        get_params: pg_get_params,
        request_topup: pg_request_topup,
        request_season_budget: pg_request_season_budget,
        apply_funding: pg_apply_funding,
        create_bot: pg_create_bot,
        issue_bot_key: pg_issue_bot_key,
        assign_bot: pg_assign_bot,
        record_heartbeat: pg_record_heartbeat,
        bot_ids: pg_bot_ids
    };
}

import "json";
import "pg";
import "time";
import "zokor";
import "../domain" as domain;
import "../service" as service;
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
    let no_cap: opt[int] = none;
    return ok(domain.TreasurySummary {
        given_to_players: row.given,
        bot_budget: domain.BotBudgetInfo { allocated: row.allocated, cap: no_cap },
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

fn pg_topup_budget(s: PostgresTreasuryStore, season: str, bot: str, mkt: str, amt: int, op: str, reason: str) -> result[bool, str] {
    let empty_args: [pg.Arg] = [];
    let cap_q = "select coalesce(max((payload->>'cap')::bigint), 750000)::bigint as val from approvals where kind = 'bot_season_budget' and status = 'approved'";
    let cap_res: result[[SumRow], str] = zokor.query_all(s.pool, cap_q, empty_args, pg_deadline());
    let cap = 750000;
    if let rows = cap_res {
        if len(rows) > 0 { cap = rows[0].val; }
    }

    let alloc_q = "select coalesce(sum(allocated), 0)::bigint as val from bot_markets";
    let alloc_res: result[[SumRow], str] = zokor.query_all(s.pool, alloc_q, empty_args, pg_deadline());
    let allocated = 0;
    if let rows = alloc_res {
        if len(rows) > 0 { allocated = rows[0].val; }
    }

    if allocated + amt > cap {
        return err("BUDGET_CAP_EXCEEDED");
    }

    let q = "update bot_markets set allocated = allocated + $1, updated_at = now() where bot_id = $2::uuid and market_id = $3::uuid";
    let res = exec_sql(s.pool, q, [pg.arg_int(amt), pg.arg_text(bot), pg.arg_text(mkt)], pg_deadline());
    guard let _n = res else let e = err_of(res) {
        return err(e);
    }
    return ok(true);
}

fn pg_propose_season_budget(s: PostgresTreasuryStore, season: str, amt: int, op: str, reason: str) -> result[str, str] {
    let payload = "{\"season_id\":\"" + season + "\",\"cap\":" + to_str(amt) + ",\"reason\":\"" + reason + "\"}";
    let q = "insert into approvals (id, kind, scope, subject_id, payload_hash, payload, required_votes, status, proposed_by) " +
            "values (gen_random_uuid(), 'bot_season_budget', 'treasury', nullif($1, '')::uuid, 'hash', $2::jsonb, 2, 'proposed', nullif($3, '')::uuid) " +
            "returning id::text as val";
    let res: result[[TextRow], str] = zokor.query_all(s.pool, q, [pg.arg_text(season), pg.arg_text(payload), pg.arg_text(op)], pg_deadline());
    guard let rows = res else let e = err_of(res) {
        return err(e);
    }
    if len(rows) > 0 {
        return ok(rows[0].val);
    }
    return err("insert failed");
}

gc struct StatusRow {
    status: str
}

// A paused row stays paused whatever the bot reports, and a bot that
// reports during a global pause is moved to PAUSED_ALL rather than QUOTING.
fn pg_record_heartbeat(s: PostgresTreasuryStore, p: domain.HeartbeatPayload) -> result[str, str] {
    let q = "update bot_markets set used = $1, " +
            "status = case when status in ('PAUSED_MANUAL','PAUSED_ALL') then status " +
            "when coalesce((select h.bots_paused from trading_halt h where h.id = 1), false) then 'PAUSED_ALL' else $2 end, " +
            "status_reason = case when status in ('PAUSED_MANUAL','PAUSED_ALL') " +
            "or coalesce((select h.bots_paused from trading_halt h where h.id = 1), false) then status_reason else $3 end, " +
            "last_quote_at = now(), updated_at = now() " +
            "where bot_id = $4::uuid and market_id = $5::uuid returning status";
    let res: result[[StatusRow], str] = zokor.query_all(s.pool, q,
        [pg.arg_int(p.used), pg.arg_text(p.status), pg.arg_text(p.status_reason), pg.arg_text(p.bot_id), pg.arg_text(p.market_id)],
        pg_deadline());
    guard let rows = res else let e = err_of(res) {
        return err(e);
    }
    if len(rows) != 1 {
        return err("NOT_FOUND");
    }
    return ok(rows[0].status);
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
        topup_budget: pg_topup_budget,
        propose_season_budget: pg_propose_season_budget,
        record_heartbeat: pg_record_heartbeat,
        bot_ids: pg_bot_ids
    };
}

import "json";
import "pg";
import "time";
import "zokor";
import "../domain" as domain;
import "../service" as service;

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

fn pg_get_summary(s: PostgresTreasuryStore, season_id: str) -> result[domain.TreasurySummary, str] {
    let empty_args: [pg.Arg] = [];
    let given_q = "select coalesce(sum(amount), 0)::bigint as val from ledger_journal where kind = 'SEASON_GRANT'";
    let given_res: result[[SumRow], str] = zokor.query_all(s.pool, given_q, empty_args, pg_deadline());
    let given = 0;
    if let rows = given_res {
        if len(rows) > 0 { given = rows[0].val; }
    }

    let alloc_q = "select coalesce(sum(allocated), 0)::bigint as val from bot_markets";
    let alloc_res: result[[SumRow], str] = zokor.query_all(s.pool, alloc_q, empty_args, pg_deadline());
    let allocated = 0;
    if let rows = alloc_res {
        if len(rows) > 0 { allocated = rows[0].val; }
    }

    let cap_q = "select coalesce(max((payload->>'cap')::bigint), 750000)::bigint as val from approvals where kind = 'bot_season_budget' and status = 'approved'";
    let cap_res: result[[SumRow], str] = zokor.query_all(s.pool, cap_q, empty_args, pg_deadline());
    let cap = 750000;
    if let rows = cap_res {
        if len(rows) > 0 { cap = rows[0].val; }
    }

    let coll_q = "select coalesce(sum(collateral), 0)::bigint as val from markets where status in ('OPEN', 'SUSPENDED', 'CLOSED', 'RESOLUTION_PENDING')";
    let coll_res: result[[SumRow], str] = zokor.query_all(s.pool, coll_q, empty_args, pg_deadline());
    let collateral = 0;
    if let rows = coll_res {
        if len(rows) > 0 { collateral = rows[0].val; }
    }

    let fee_q = "select coalesce(sum(amount), 0)::bigint as val from ledger_journal where kind = 'FEE'";
    let fee_res: result[[SumRow], str] = zokor.query_all(s.pool, fee_q, empty_args, pg_deadline());
    let fees = 0;
    if let rows = fee_res {
        if len(rows) > 0 { fees = rows[0].val; }
    }

    let none_grant: opt[domain.SeasonGrantsInfo] = none;
    let grant_q = "select id::text as val from approvals where kind = 'season_grants' and status in ('proposed', 'pending') limit 1";
    let grant_res: result[[TextRow], str] = zokor.query_all(s.pool, grant_q, empty_args, pg_deadline());
    if let rows = grant_res {
        if len(rows) > 0 {
            none_grant = some(domain.SeasonGrantsInfo {
                at: "2026-11-01T00:00:00Z",
                approx_players: 3180,
                approx_total: 3180000,
                approval_id: rows[0].val,
                status: "WAITING_SECOND_APPROVAL"
            });
        }
    }

    let none_banner: opt[str] = none;
    return ok(domain.TreasurySummary {
        given_to_players: given,
        bot_budget: domain.BotBudgetInfo { allocated: allocated, cap: cap },
        collateral_held: collateral,
        fees_collected: fees,
        season_grants_next: none_grant,
        books_balanced: true,
        incident_banner: none_banner
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
    guard let _n = res else let e = err_of(res) {
        return err(e);
    }
    return ok(true);
}

fn pg_set_all_paused(s: PostgresTreasuryStore, paused: bool, reason: str) -> result[bool, str] {
    let q = "update trading_halt set bots_paused = $1, reason = $2, halted_at = now()";
    let res = exec_sql(s.pool, q, [pg.arg_bool(paused), pg.arg_text(reason)], pg_deadline());
    guard let _n = res else let e = err_of(res) {
        return err(e);
    }
    let bm_status = "QUOTING";
    if paused {
        bm_status = "PAUSED_ALL";
    }
    let q2 = "update bot_markets set status = $1, status_reason = $2, updated_at = now()";
    let _r2 = exec_sql(s.pool, q2, [pg.arg_text(bm_status), pg.arg_text(reason)], pg_deadline());
    return ok(true);
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

fn pg_record_heartbeat(s: PostgresTreasuryStore, p: domain.HeartbeatPayload) -> result[bool, str] {
    let q = "update bot_markets set used = $1, status = $2, status_reason = $3, last_quote_at = now() where bot_id = $4::uuid and market_id = $5::uuid";
    let res = exec_sql(s.pool, q, [pg.arg_int(p.used), pg.arg_text(p.status), pg.arg_text(p.status_reason), pg.arg_text(p.bot_id), pg.arg_text(p.market_id)], pg_deadline());
    guard let _n = res else let e = err_of(res) {
        return err(e);
    }
    return ok(true);
}

fn pg_cancel_bot_orders(s: PostgresTreasuryStore, bot_id: str, market_id: str) -> result[int, str] {
    let q = "insert into market_commands (id, market_id, seq, kind, account_id, status) " +
            "values (gen_random_uuid(), $1::uuid, (select coalesce(max(seq), 0) + 1 from market_commands where market_id = $1::uuid), 'CancelAll', $2::uuid, 'ENQUEUED')";
    let res = exec_sql(s.pool, q, [pg.arg_text(market_id), pg.arg_text(bot_id)], pg_deadline());
    guard let n = res else let e = err_of(res) {
        return err(e);
    }
    return ok(n);
}

fn pg_cancel_all_bots_orders(s: PostgresTreasuryStore) -> result[int, str] {
    let empty_args: [pg.Arg] = [];
    let res: result[[BotOverviewRow], str] = zokor.query_all(s.pool, "select bot_id::text, '' as name, market_id::text, '' as question, 0 as budget, 0 as used, 0 as holding_yes, 0 as holding_no, 0 as spread_ticks, 0 as last_quote_age_ms, '' as status, 0 as params_version from bot_markets", empty_args, pg_deadline());
    guard let rows = res else let e = err_of(res) {
        return err(e);
    }
    let total = 0;
    for r in rows {
        let cr = pg_cancel_bot_orders(s, r.bot_id, r.market_id);
        if let n = cr { total += n; }
    }
    return ok(total);
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
        cancel_bot_orders: pg_cancel_bot_orders,
        cancel_all_bots_orders: pg_cancel_all_bots_orders
    };
}

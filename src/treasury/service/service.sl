import "../domain" as domain;

pub gc struct TreasuryService[C] {
    store: TreasuryStore[C]
}

pub fn new_treasury_service[C](store: TreasuryStore[C]) -> TreasuryService[C] {
    return TreasuryService[C] { store: store };
}

pub fn get_summary[C](s: TreasuryService[C], season_id: str) -> result[domain.TreasurySummary, str] {
    return (s.store.get_summary)(s.store.context, season_id);
}

pub fn list_bots[C](s: TreasuryService[C]) -> result[[domain.BotOverview], str] {
    return (s.store.list_bots)(s.store.context);
}

pub fn list_decisions[C](s: TreasuryService[C], bot_id: str, market_id: str, limit: int) -> result[[domain.BotDecisionRecord], str] {
    let lim = limit;
    if lim <= 0 {
        lim = 50;
    }
    if lim > 200 {
        lim = 200;
    }
    return (s.store.list_decisions)(s.store.context, bot_id, market_id, lim);
}

pub fn pause_bot[C, Q](s: TreasuryService[C], orders: BotOrders[Q], bot_id: str, market_id: str, reason: str) -> result[bool, str] {
    let res = (s.store.set_status)(s.store.context, bot_id, market_id, "PAUSED_MANUAL", reason);
    guard let _ok = res else let e = err_of(res) {
        return err(e);
    }
    let pulled = pull_quotes(orders, bot_id, market_id);
    guard let _n = pulled else let e = err_of(pulled) {
        return err(e);
    }
    return ok(true);
}

pub fn resume_bot[C](s: TreasuryService[C], bot_id: str, market_id: str, reason: str) -> result[bool, str] {
    return (s.store.set_status)(s.store.context, bot_id, market_id, "QUOTING", reason);
}

pub fn pause_all_bots[C, Q](s: TreasuryService[C], orders: BotOrders[Q], reason: str) -> result[bool, str] {
    let res = (s.store.set_all_paused)(s.store.context, true, reason);
    guard let _ok = res else let e = err_of(res) {
        return err(e);
    }
    let ids_res = (s.store.bot_ids)(s.store.context);
    guard let ids = ids_res else let e = err_of(ids_res) {
        return err("CANCEL_FAILED: " + e);
    }
    let failed = 0;
    let first = "";
    for bot_id in ids {
        let pulled = pull_quotes(orders, bot_id, "");
        guard let _n = pulled else let e = err_of(pulled) {
            failed += 1;
            if len(first) == 0 { first = e; }
            continue;
        }
    }
    if failed > 0 {
        return err(first);
    }
    return ok(true);
}

// Every market is attempted even after a failure, so one stuck market never
// leaves the bot quoting everywhere else. "" means all of the bot's markets.
fn pull_quotes[Q](orders: BotOrders[Q], bot_id: str, only_market: str) -> result[int, str] {
    let open_res = (orders.open_markets)(orders.context, bot_id);
    guard let open = open_res else let e = err_of(open_res) {
        return err("CANCEL_FAILED: " + e);
    }
    let cancelled = 0;
    let failed = 0;
    let first = "";
    for market_id in open {
        if len(only_market) > 0 && market_id != only_market {
            continue;
        }
        let r = (orders.cancel_all)(orders.context, market_id, bot_id);
        if let _ok = r {
            cancelled += 1;
        } else let e = err_of(r) {
            failed += 1;
            if len(first) == 0 { first = market_id + ": " + e; }
        }
    }
    if failed > 0 {
        return err("CANCEL_FAILED: " + to_str(failed) + " market(s), first " + first);
    }
    return ok(cancelled);
}

pub fn resume_all_bots[C](s: TreasuryService[C], reason: str) -> result[bool, str] {
    return (s.store.set_all_paused)(s.store.context, false, reason);
}

pub fn patch_params[C](
    s: TreasuryService[C],
    bot_id: str,
    market_id: str,
    params: domain.BotParams,
    operator_id: str,
    expected_version: int
) -> result[int, str] {
    if params.base_spread_ticks < 1 {
        return err("base_spread_ticks must be >= 1");
    }
    if params.levels < 1 || params.levels > 10 {
        return err("levels must be between 1 and 10");
    }
    if params.base_size < 1 {
        return err("base_size must be >= 1");
    }
    if params.max_net_shares < 1 {
        return err("max_net_shares must be >= 1");
    }
    return (s.store.update_params)(s.store.context, bot_id, market_id, params, operator_id, expected_version);
}

pub fn topup_budget[C](
    s: TreasuryService[C],
    season_id: str,
    bot_id: str,
    market_id: str,
    amount: int,
    operator_id: str,
    reason: str
) -> result[bool, str] {
    if amount <= 0 {
        return err("amount must be positive");
    }
    return (s.store.topup_budget)(s.store.context, season_id, bot_id, market_id, amount, operator_id, reason);
}

pub fn propose_season_budget[C](
    s: TreasuryService[C],
    season_id: str,
    amount: int,
    operator_id: str,
    reason: str
) -> result[str, str] {
    if amount <= 0 {
        return err("amount must be positive");
    }
    return (s.store.propose_season_budget)(s.store.context, season_id, amount, operator_id, reason);
}

// The bot reports what it is doing, never that it is paused: pauses are an
// operator's decision, and the store keeps them whatever a heartbeat says.
pub fn record_heartbeat[C](s: TreasuryService[C], payload: domain.HeartbeatPayload) -> result[domain.BotDirective, str] {
    if len(payload.market_id) != 36 || !domain.bot_reportable_status(payload.status) || len(payload.status_reason) > 200 ||
       payload.used < 0 || payload.holding_yes < 0 || payload.holding_no < 0 || payload.spread_ticks < 0 {
        return err("INVALID_HEARTBEAT");
    }
    let recorded = (s.store.record_heartbeat)(s.store.context, payload);
    guard let d = recorded else let e = err_of(recorded) {
        return err(e);
    }
    let params_res = (s.store.get_params)(s.store.context, payload.bot_id, payload.market_id);
    guard let found = params_res else let e = err_of(params_res) {
        return err(e);
    }
    if let p = found {
        d.params = p;
    }
    return ok(d);
}

pub fn save_decisions[C](s: TreasuryService[C], records: [domain.BotDecisionRecord]) -> result[bool, str] {
    return (s.store.save_decisions)(s.store.context, records);
}

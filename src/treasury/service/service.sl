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

pub fn pause_bot[C](s: TreasuryService[C], bot_id: str, market_id: str, reason: str) -> result[bool, str] {
    let res = (s.store.set_status)(s.store.context, bot_id, market_id, "PAUSED_MANUAL", reason);
    guard let _ok = res else let e = err_of(res) {
        return err(e);
    }
    let _cancelled = (s.store.cancel_bot_orders)(s.store.context, bot_id, market_id);
    return ok(true);
}

pub fn resume_bot[C](s: TreasuryService[C], bot_id: str, market_id: str, reason: str) -> result[bool, str] {
    return (s.store.set_status)(s.store.context, bot_id, market_id, "QUOTING", reason);
}

pub fn pause_all_bots[C](s: TreasuryService[C], reason: str) -> result[bool, str] {
    let res = (s.store.set_all_paused)(s.store.context, true, reason);
    guard let _ok = res else let e = err_of(res) {
        return err(e);
    }
    let _cancelled = (s.store.cancel_all_bots_orders)(s.store.context);
    return ok(true);
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

pub fn record_heartbeat[C](s: TreasuryService[C], payload: domain.HeartbeatPayload) -> result[bool, str] {
    return (s.store.record_heartbeat)(s.store.context, payload);
}

pub fn save_decisions[C](s: TreasuryService[C], records: [domain.BotDecisionRecord]) -> result[bool, str] {
    return (s.store.save_decisions)(s.store.context, records);
}

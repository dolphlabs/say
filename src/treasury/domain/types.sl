pub gc struct SeasonGrantsInfo {
    at: str,
    amount: int,
    approx_players: int,
    approx_total: int,
    approval_id: str,
    status: str
}

pub gc struct BotBudgetInfo {
    allocated: int,
    cap: opt[int]
}

pub gc struct TreasurySummary {
    given_to_players: int,
    bot_budget: BotBudgetInfo,
    collateral_held: int,
    fees_collected: int,
    season_grants_next: opt[SeasonGrantsInfo],
    books_balanced: opt[bool],
    incident_banner: opt[str]
}

pub gc struct MarketBrief {
    id: str,
    question: str
}

pub gc struct BotHolding {
    yes: int,
    no: int
}

pub gc struct BotOverview {
    bot_id: str,
    name: str,
    market: MarketBrief,
    budget: int,
    used: int,
    holding: BotHolding,
    spread_ticks: int,
    last_quote_age_ms: int,
    status: str,
    status_label: str,
    params_version: int
}

pub gc struct BotDecisionRecord {
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

pub gc struct HeartbeatPayload {
    bot_id: str,
    market_id: str,
    status: str,
    status_reason: str,
    holding_yes: int,
    holding_no: int,
    used: int,
    spread_ticks: int
}

pub fn bot_reportable_status(status: str) -> bool {
    return status == "QUOTING" || status == "PULLED_STALE" || status == "PULLED_CAP" ||
        status == "PULLED_DRAWDOWN" || status == "PULLED_MARKET";
}

// What a bot is told after each heartbeat: the status in force and the
// limits it quotes within. Only the server knows pauses and allocations.
pub gc struct BotDirective {
    status: str,
    allocated: int,
    trading_halted: bool,
    params_version: int,
    params: BotParams
}

// The reference price: the last trade, else the middle of the book, else
// the price the market opened at.
pub fn reference_price(last: opt[int], best_bid: opt[int], best_ask: opt[int], opening: int) -> int {
    if let l = last { return l; }
    if let b = best_bid {
        if let a = best_ask { return (b + a) / 2; }
    }
    return opening;
}

// Cost of a holding from its average price, rounded up so the worst-case
// loss is never understated.
pub fn holding_cost(qty: int, avg_num: int, avg_den: int) -> int {
    if qty <= 0 || avg_den <= 0 || avg_num <= 0 { return 0; }
    return (qty * avg_num + avg_den - 1) / avg_den;
}

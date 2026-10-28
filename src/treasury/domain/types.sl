pub gc struct SeasonGrantsInfo {
    at: str,
    approx_players: int,
    approx_total: int,
    approval_id: str,
    status: str
}

pub gc struct BotBudgetInfo {
    allocated: int,
    cap: int
}

pub gc struct TreasurySummary {
    given_to_players: int,
    bot_budget: BotBudgetInfo,
    collateral_held: int,
    fees_collected: int,
    season_grants_next: opt[SeasonGrantsInfo],
    books_balanced: bool,
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

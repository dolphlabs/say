import "../domain" as domain;

pub gc struct TreasuryStore[C] {
    context: C,
    get_summary: fn(C, str) -> result[domain.TreasurySummary, str],
    list_bots: fn(C) -> result[[domain.BotOverview], str],
    list_decisions: fn(C, str, str, int) -> result[[domain.BotDecisionRecord], str],
    save_decisions: fn(C, [domain.BotDecisionRecord]) -> result[bool, str],
    set_status: fn(C, str, str, str, str) -> result[bool, str],
    set_all_paused: fn(C, bool, str) -> result[bool, str],
    is_all_paused: fn(C) -> result[bool, str],
    update_params: fn(C, str, str, domain.BotParams, str, int) -> result[int, str],
    get_params: fn(C, str, str) -> result[opt[domain.BotParams], str],
    topup_budget: fn(C, str, str, str, int, str, str) -> result[bool, str],
    propose_season_budget: fn(C, str, int, str, str) -> result[str, str],
    record_heartbeat: fn(C, domain.HeartbeatPayload) -> result[str, str],
    bot_ids: fn(C) -> result[[str], str]
}

// The exchange owns orders, so pulling a bot's quotes goes through its
// command queue, never through the treasury's own tables.
pub gc struct BotOrders[Q] {
    context: Q,
    open_markets: fn(Q, str) -> result[[str], str],
    cancel_all: fn(Q, str, str) -> result[bool, str]
}

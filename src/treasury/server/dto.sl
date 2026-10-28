import "zokor";
import "../domain" as domain;

pub gc struct PauseReasonDto {
    reason: str
}

pub gc struct PatchBotParamsDto {
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

pub gc struct PatchParamsRequestDto {
    params: PatchBotParamsDto,
    version: int
}

pub gc struct TopupDto {
    amount: int,
    reason: str
}

pub gc struct SeasonBudgetDto {
    season: str,
    amount: int,
    reason: str
}

pub gc struct HeartbeatDto {
    bot_id: str,
    market_id: str,
    status: str,
    status_reason: str,
    holding_yes: int,
    holding_no: int,
    used: int,
    spread_ticks: int
}

pub fn summary_json(s: domain.TreasurySummary) -> zokor.Json {
    let j = zokor.jobj();
    j.set_int("given_to_players", s.given_to_players);

    let b_obj = zokor.jobj();
    b_obj.set_int("allocated", s.bot_budget.allocated);
    b_obj.set_int("cap", s.bot_budget.cap);
    j.set("bot_budget", b_obj);

    j.set_int("collateral_held", s.collateral_held);
    j.set_int("fees_collected", s.fees_collected);

    if let g = s.season_grants_next {
        let g_obj = zokor.jobj();
        g_obj.set_str("at", g.at);
        g_obj.set_int("approx_players", g.approx_players);
        g_obj.set_int("approx_total", g.approx_total);
        g_obj.set_str("approval_id", g.approval_id);
        g_obj.set_str("status", g.status);
        j.set("season_grants_next", g_obj);
    } else {
        j.set("season_grants_next", zokor.jnull());
    }

    j.set_bool("books_balanced", s.books_balanced);
    if let b = s.incident_banner {
        j.set_str("incident_banner", b);
    } else {
        j.set("incident_banner", zokor.jnull());
    }
    return j;
}

pub fn bot_overview_json(b: domain.BotOverview) -> zokor.Json {
    let j = zokor.jobj();
    j.set_str("bot_id", b.bot_id);
    j.set_str("name", b.name);

    let m_obj = zokor.jobj();
    m_obj.set_str("id", b.market.id);
    m_obj.set_str("question", b.market.question);
    j.set("market", m_obj);

    j.set_int("budget", b.budget);
    j.set_int("used", b.used);

    let h_obj = zokor.jobj();
    h_obj.set_int("yes", b.holding.yes);
    h_obj.set_int("no", b.holding.no);
    j.set("holding", h_obj);

    j.set_int("spread_ticks", b.spread_ticks);
    j.set_int("last_quote_age_ms", b.last_quote_age_ms);
    j.set_str("status", b.status);
    j.set_str("status_label", b.status_label);
    j.set_int("params_version", b.params_version);
    return j;
}

pub fn decision_json(d: domain.BotDecisionRecord) -> zokor.Json {
    let j = zokor.jobj();
    j.set_str("id", d.id);
    j.set_str("bot_id", d.bot_id);
    j.set_str("market_id", d.market_id);
    j.set_str("at", d.at);
    j.set_str("inputs_digest", d.inputs_digest);
    j.set_int("r", d.r);
    j.set_int("r_prime", d.r_prime);
    j.set_int("spread", d.spread);
    j.set_int("util", d.util);
    j.set_int("worst_case_loss", d.worst_case_loss);
    j.set_str("status", d.status);
    return j;
}

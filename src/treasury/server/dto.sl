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
    if let cap = s.bot_budget.cap {
        b_obj.set_int("cap", cap);
    } else {
        b_obj.set("cap", zokor.jnull());
    }
    j.set("bot_budget", b_obj);

    j.set_int("collateral_held", s.collateral_held);
    j.set_int("fees_collected", s.fees_collected);

    if let g = s.season_grants_next {
        let g_obj = zokor.jobj();
        g_obj.set_str("at", g.at);
        g_obj.set_int("amount", g.amount);
        g_obj.set_int("approx_players", g.approx_players);
        g_obj.set_int("approx_total", g.approx_total);
        g_obj.set_str("approval_id", g.approval_id);
        g_obj.set_str("status", g.status);
        j.set("season_grants_next", g_obj);
    } else {
        j.set("season_grants_next", zokor.jnull());
    }

    if let balanced = s.books_balanced {
        j.set_bool("books_balanced", balanced);
    } else {
        j.set("books_balanced", zokor.jnull());
    }
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

pub fn directive_json(d: domain.BotDirective) -> zokor.Json {
    let p = d.params;
    return zokor.jobj()
        .set_str("status", d.status)
        .set_int("allocated", d.allocated)
        .set_bool("trading_halted", d.trading_halted)
        .set_int("params_version", d.params_version)
        .set("params", zokor.jobj()
            .set_int("base_spread_ticks", p.base_spread_ticks).set_int("vol_ticks", p.vol_ticks)
            .set_int("skew_ticks", p.skew_ticks).set_int("levels", p.levels).set_int("base_size", p.base_size)
            .set_int("max_net_shares", p.max_net_shares).set_int("max_loss", p.max_loss)
            .set_int("season_max_drawdown", p.season_max_drawdown).set_int("min_requote_ms", p.min_requote_ms)
            .set_int("max_ops_per_sec", p.max_ops_per_sec).set_int("max_open_orders", p.max_open_orders));
}

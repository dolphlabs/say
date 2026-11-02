import "../domain" as domain;

pub fn test_treasury_dto_serialization() {
    let summary = domain.TreasurySummary {
        given_to_players: 3180000,
        bot_budget: domain.BotBudgetInfo { allocated: 502000, cap: none },
        collateral_held: 1420500,
        fees_collected: 34200,
        season_grants_next: some(domain.SeasonGrantsInfo {
            at: "2026-11-01T00:00:00Z",
            amount: 1000,
            approx_players: 3180,
            approx_total: 3180000,
            approval_id: "appr_019283",
            status: "WAITING_SECOND_APPROVAL"
        }),
        books_balanced: none,
        incident_banner: none
    };

    let j = summary_json(summary);
    let s = j.render();
    assert(len(s) > 0, "summary json rendered");
    assert(j.get("bot_budget").get("cap").is_null(), s);
    assert(j.get("books_balanced").is_null(), s);
    assert(j.get("season_grants_next").get("amount").int_or(0) == 1000, s);
    let checked = summary_json(domain.TreasurySummary {
        given_to_players: 0,
        bot_budget: domain.BotBudgetInfo { allocated: 0, cap: some(750000) },
        collateral_held: 0,
        fees_collected: 0,
        season_grants_next: none,
        books_balanced: some(false),
        incident_banner: some("collateral check failed")
    });
    assert(checked.get("bot_budget").get("cap").int_or(0) == 750000, checked.render());
    assert(!checked.get("books_balanced").bool_or(true), checked.render());
    assert(checked.get("incident_banner").str_or("") == "collateral check failed", checked.render());

    let bot = domain.BotOverview {
        bot_id: "b0a12e34-5678-4901-abcd-ef0123456789",
        name: "mm-football-01",
        market: domain.MarketBrief {
            id: "m1a12e34-5678-4901-abcd-ef0123456789",
            question: "Will Remo Stars defeat Sporting Lagos?"
        },
        budget: 50000,
        used: 45500,
        holding: domain.BotHolding { yes: 140, no: 0 },
        spread_ticks: 3,
        last_quote_age_ms: 420,
        status: "QUOTING",
        status_label: "Quoting",
        params_version: 2
    };

    let bj = bot_overview_json(bot);
    let bs = bj.render();
    assert(len(bs) > 0, "bot overview json rendered");
}

import "../domain" as domain;

gc struct FakeTreasuryStore {
    calls: [str],
    summary_data: domain.TreasurySummary,
    bots_data: [domain.BotOverview],
    decisions_data: [domain.BotDecisionRecord],
    all_paused: bool,
    params_version: int,
    failure: str
}

fn fake_store() -> FakeTreasuryStore {
    let calls: [str] = [];
    return FakeTreasuryStore {
        calls: calls,
        summary_data: domain.TreasurySummary {
            given_to_players: 1000000,
            bot_budget: domain.BotBudgetInfo { allocated: 50000, cap: 100000 },
            collateral_held: 20000,
            fees_collected: 5000,
            season_grants_next: none,
            books_balanced: true,
            incident_banner: none
        },
        bots_data: [],
        decisions_data: [],
        all_paused: false,
        params_version: 1,
        failure: ""
    };
}

fn fake_get_summary(f: FakeTreasuryStore, season_id: str) -> result[domain.TreasurySummary, str] {
    push(f.calls, "summary " + season_id);
    if len(f.failure) > 0 { return err(f.failure); }
    return ok(f.summary_data);
}

fn fake_list_bots(f: FakeTreasuryStore) -> result[[domain.BotOverview], str] {
    push(f.calls, "list_bots");
    if len(f.failure) > 0 { return err(f.failure); }
    return ok(f.bots_data);
}

fn fake_list_decisions(f: FakeTreasuryStore, bot_id: str, market_id: str, limit: int) -> result[[domain.BotDecisionRecord], str] {
    push(f.calls, "list_decisions " + bot_id + " " + market_id);
    if len(f.failure) > 0 { return err(f.failure); }
    return ok(f.decisions_data);
}

fn fake_save_decisions(f: FakeTreasuryStore, records: [domain.BotDecisionRecord]) -> result[bool, str] {
    push(f.calls, "save_decisions " + to_str(len(records)));
    if len(f.failure) > 0 { return err(f.failure); }
    return ok(true);
}

fn fake_set_status(f: FakeTreasuryStore, bot_id: str, market_id: str, status: str, reason: str) -> result[bool, str] {
    push(f.calls, "set_status " + bot_id + " " + market_id + " " + status);
    if len(f.failure) > 0 { return err(f.failure); }
    return ok(true);
}

fn fake_set_all_paused(f: FakeTreasuryStore, paused: bool, reason: str) -> result[bool, str] {
    f.all_paused = paused;
    push(f.calls, "set_all_paused " + to_str(paused));
    if len(f.failure) > 0 { return err(f.failure); }
    return ok(true);
}

fn fake_is_all_paused(f: FakeTreasuryStore) -> result[bool, str] {
    return ok(f.all_paused);
}

fn fake_update_params(f: FakeTreasuryStore, bot_id: str, market_id: str, p: domain.BotParams, op: str, exp_ver: int) -> result[int, str] {
    f.params_version += 1;
    push(f.calls, "update_params " + bot_id + " " + market_id + " v=" + to_str(f.params_version));
    if len(f.failure) > 0 { return err(f.failure); }
    return ok(f.params_version);
}

fn fake_get_params(f: FakeTreasuryStore, bot_id: str, market_id: str) -> result[opt[domain.BotParams], str] {
    let p: opt[domain.BotParams] = some(domain.default_params());
    return ok(p);
}

fn fake_topup_budget(f: FakeTreasuryStore, season: str, bot: str, mkt: str, amt: int, op: str, reason: str) -> result[bool, str] {
    push(f.calls, "topup " + bot + " " + mkt + " amt=" + to_str(amt));
    if len(f.failure) > 0 { return err(f.failure); }
    return ok(true);
}

fn fake_propose_season_budget(f: FakeTreasuryStore, season: str, amt: int, op: str, reason: str) -> result[str, str] {
    push(f.calls, "propose_season_budget " + season + " amt=" + to_str(amt));
    if len(f.failure) > 0 { return err(f.failure); }
    return ok("appr_fake_123");
}

fn fake_record_heartbeat(f: FakeTreasuryStore, p: domain.HeartbeatPayload) -> result[bool, str] {
    push(f.calls, "heartbeat " + p.bot_id + " " + p.market_id);
    if len(f.failure) > 0 { return err(f.failure); }
    return ok(true);
}

fn fake_cancel_bot_orders(f: FakeTreasuryStore, bot_id: str, market_id: str) -> result[int, str] {
    push(f.calls, "cancel_bot_orders " + bot_id + " " + market_id);
    return ok(2);
}

fn fake_cancel_all_bots_orders(f: FakeTreasuryStore) -> result[int, str] {
    push(f.calls, "cancel_all_bots_orders");
    return ok(10);
}

fn fake_treasury_service(f: FakeTreasuryStore) -> TreasuryService[FakeTreasuryStore] {
    return new_treasury_service(TreasuryStore[FakeTreasuryStore] {
        context: f,
        get_summary: fake_get_summary,
        list_bots: fake_list_bots,
        list_decisions: fake_list_decisions,
        save_decisions: fake_save_decisions,
        set_status: fake_set_status,
        set_all_paused: fake_set_all_paused,
        is_all_paused: fake_is_all_paused,
        update_params: fake_update_params,
        get_params: fake_get_params,
        topup_budget: fake_topup_budget,
        propose_season_budget: fake_propose_season_budget,
        record_heartbeat: fake_record_heartbeat,
        cancel_bot_orders: fake_cancel_bot_orders,
        cancel_all_bots_orders: fake_cancel_all_bots_orders
    });
}

import "strings";
import "../domain" as domain;

pub fn test_treasury_summary() {
    let f = fake_store();
    let svc = fake_treasury_service(f);
    let res = get_summary(svc, "season_1");
    guard let sum = res else { panic("get_summary failed"); }
    assert(sum.given_to_players == 1000000);
    assert(sum.bot_budget.allocated == 50000);
    assert((sum.bot_budget.cap ?? 0) == 100000);
    assert(f.calls[0] == "summary season_1");
}

pub fn test_pause_and_resume_bot() {
    let f = fake_store();
    let o = fake_orders();
    let svc = fake_treasury_service(f);
    let p_res = pause_bot(svc, fake_bot_orders(o), "bot_1", "mkt_1", "manual review");
    guard let _ok1 = p_res else { panic("pause_bot failed"); }
    assert(f.calls[0] == "set_status bot_1 mkt_1 PAUSED_MANUAL");
    assert(len(o.calls) == 1);
    assert(o.calls[0] == "cancel_all bot_1 mkt_1");

    let r_res = resume_bot(svc, "bot_1", "mkt_1", "review complete");
    guard let _ok2 = r_res else { panic("resume_bot failed"); }
    assert(f.calls[1] == "set_status bot_1 mkt_1 QUOTING");
}

pub fn test_should_not_enqueue_a_cancel_when_the_bot_has_no_orders_in_that_market() {
    let f = fake_store();
    let o = fake_orders();
    let svc = fake_treasury_service(f);
    let p_res = pause_bot(svc, fake_bot_orders(o), "bot_2", "mkt_9", "manual review");
    guard let _ok = p_res else { panic("pause without orders failed"); }
    assert(len(o.calls) == 0);
}

pub fn test_should_report_a_pause_whose_cancel_could_not_be_enqueued() {
    let f = fake_store();
    let o = fake_orders();
    o.failing_market = "mkt_1";
    let svc = fake_treasury_service(f);
    let p_res = pause_bot(svc, fake_bot_orders(o), "bot_1", "mkt_1", "manual review");
    if let _ok = p_res { panic("a failed cancel was reported as a successful pause"); }
    else let e = err_of(p_res) { assert(strings.has_prefix(e, "CANCEL_FAILED"), e); }
    assert(f.calls[0] == "set_status bot_1 mkt_1 PAUSED_MANUAL");
}

pub fn test_should_report_a_pause_when_open_orders_cannot_be_read() {
    let f = fake_store();
    let o = fake_orders();
    o.open_failure = "connection refused";
    let svc = fake_treasury_service(f);
    let p_res = pause_bot(svc, fake_bot_orders(o), "bot_1", "mkt_1", "manual review");
    if let _ok = p_res { panic("an unreadable order list was reported as a successful pause"); }
    else let e = err_of(p_res) { assert(strings.has_prefix(e, "CANCEL_FAILED"), e); }
}

pub fn test_should_return_not_found_when_pausing_an_unknown_bot() {
    let f = fake_store();
    f.failure = "NOT_FOUND";
    let o = fake_orders();
    let svc = fake_treasury_service(f);
    let p_res = pause_bot(svc, fake_bot_orders(o), "bot_x", "mkt_1", "manual review");
    if let _ok = p_res { panic("unknown bot paused"); }
    else let e = err_of(p_res) { assert(e == "NOT_FOUND", e); }
    assert(len(o.calls) == 0);
}

pub fn test_pause_and_resume_all_bots() {
    let f = fake_store();
    let o = fake_orders();
    let svc = fake_treasury_service(f);
    let p_res = pause_all_bots(svc, fake_bot_orders(o), "emergency stop");
    guard let _ok1 = p_res else { panic("pause_all_bots failed"); }
    assert(f.calls[0] == "set_all_paused true");
    assert(f.calls[1] == "bot_ids");
    assert(len(o.calls) == 3);
    assert(o.calls[0] == "cancel_all bot_1 mkt_1");
    assert(o.calls[1] == "cancel_all bot_1 mkt_2");
    assert(o.calls[2] == "cancel_all bot_2 mkt_3");

    let r_res = resume_all_bots(svc, "emergency cleared");
    guard let _ok2 = r_res else { panic("resume_all_bots failed"); }
    assert(f.calls[2] == "set_all_paused false");
}

pub fn test_should_still_cancel_other_markets_when_one_cancel_fails_during_pause_all() {
    let f = fake_store();
    let o = fake_orders();
    o.failing_market = "mkt_1";
    let svc = fake_treasury_service(f);
    let p_res = pause_all_bots(svc, fake_bot_orders(o), "emergency stop");
    if let _ok = p_res { panic("a failed cancel was reported as a successful pause"); }
    else let e = err_of(p_res) { assert(strings.has_prefix(e, "CANCEL_FAILED"), e); }
    assert(len(o.calls) == 3);
}

fn heartbeat(market_id: str, status: str, used: int) -> domain.HeartbeatPayload {
    return domain.HeartbeatPayload {
        bot_id: "bot_1", market_id: market_id, status: status,
        status_reason: "normal", holding_yes: 0, holding_no: 0, used: used, spread_ticks: 3
    };
}

pub fn test_should_reject_a_heartbeat_that_claims_a_pause_or_has_bad_numbers() {
    let f = fake_store();
    let svc = fake_treasury_service(f);
    let market = "00000000-0000-4000-a000-000000000200";
    let ok_res = record_heartbeat(svc, heartbeat(market, "QUOTING", 0));
    guard let directive = ok_res else { panic("valid heartbeat refused"); }
    assert(directive.status == "QUOTING");
    assert(directive.allocated == 5000);
    assert(directive.params.levels == domain.default_params().levels);

    for bad in [heartbeat(market, "PAUSED_MANUAL", 0), heartbeat(market, "PAUSED_ALL", 0),
                heartbeat(market, "QUOTING", -1), heartbeat("not-a-market", "QUOTING", 0)] {
        let r = record_heartbeat(svc, bad);
        if let _s = r { panic("invalid heartbeat accepted: " + bad.status); }
        else let e = err_of(r) { assert(e == "INVALID_HEARTBEAT", e); }
    }
    assert(len(f.calls) == 1);
}

pub fn test_patch_params_validation() {
    let f = fake_store();
    let svc = fake_treasury_service(f);
    let bad_params = domain.default_params();
    bad_params.base_spread_ticks = 0;
    let res = patch_params(svc, "bot_1", "mkt_1", bad_params, "op_1", 1);
    if let _ok = res { panic("base_spread_ticks < 1 should fail"); }

    let good_params = domain.default_params();
    let res2 = patch_params(svc, "bot_1", "mkt_1", good_params, "op_1", 1);
    guard let new_v = res2 else { panic("valid patch_params should succeed"); }
    assert(new_v == 2);
}

pub fn test_topup_and_season_budget() {
    let f = fake_store();
    let svc = fake_treasury_service(f);
    let t_res = topup_budget(svc, "s1", "b1", "m1", 10000, "op_1", "volume increase");
    guard let _ok1 = t_res else { panic("topup failed"); }

    let b_res = propose_season_budget(svc, "s1", 500000, "op_1", "initial budget");
    guard let appr_id = b_res else { panic("propose_season_budget failed"); }
    assert(appr_id == "appr_fake_123");
}

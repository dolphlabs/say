import "../domain" as domain;

pub fn test_treasury_summary() {
    let f = fake_store();
    let svc = fake_treasury_service(f);
    let res = get_summary(svc, "season_1");
    guard let sum = res else { panic("get_summary failed"); }
    assert(sum.given_to_players == 1000000);
    assert(sum.bot_budget.allocated == 50000);
    assert(sum.bot_budget.cap == 100000);
    assert(f.calls[0] == "summary season_1");
}

pub fn test_pause_and_resume_bot() {
    let f = fake_store();
    let svc = fake_treasury_service(f);
    let p_res = pause_bot(svc, "bot_1", "mkt_1", "manual review");
    guard let _ok1 = p_res else { panic("pause_bot failed"); }
    assert(f.calls[0] == "set_status bot_1 mkt_1 PAUSED_MANUAL");
    assert(f.calls[1] == "cancel_bot_orders bot_1 mkt_1");

    let r_res = resume_bot(svc, "bot_1", "mkt_1", "review complete");
    guard let _ok2 = r_res else { panic("resume_bot failed"); }
    assert(f.calls[2] == "set_status bot_1 mkt_1 QUOTING");
}

pub fn test_pause_and_resume_all_bots() {
    let f = fake_store();
    let svc = fake_treasury_service(f);
    let p_res = pause_all_bots(svc, "emergency stop");
    guard let _ok1 = p_res else { panic("pause_all_bots failed"); }
    assert(f.calls[0] == "set_all_paused true");
    assert(f.calls[1] == "cancel_all_bots_orders");

    let r_res = resume_all_bots(svc, "emergency cleared");
    guard let _ok2 = r_res else { panic("resume_all_bots failed"); }
    assert(f.calls[2] == "set_all_paused false");
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

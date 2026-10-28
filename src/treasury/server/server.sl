// zokor:public
import "http";
import "zokor";
import "../../platform/app" as app;
import "../../platform/auth" as auth;
import "../domain" as domain;
import "../service" as treasury_svc;

pub fn mount(r: zokor.Router[app.App]) -> int {
    register_errors(r.errors);

    let adm = r.group("/v1/admin");
    adm.before(auth.require_session);

    adm.get("/treasury/summary", get_summary_handler);
    adm.get("/bots", list_bots_handler);
    adm.get("/bots/:bot_id/markets/:market_id/decisions", list_decisions_handler);
    adm.post("/bots/:bot_id/markets/:market_id/pause", pause_bot_handler);
    adm.post("/bots/:bot_id/markets/:market_id/resume", resume_bot_handler);
    adm.post("/bots/pause-all", pause_all_handler);
    adm.post("/bots/resume-all", resume_all_handler);
    adm.patch("/bots/:bot_id/markets/:market_id/params", patch_params_handler);
    adm.post("/bots/:bot_id/markets/:market_id/topup", topup_handler);
    adm.post("/treasury/season-budget", season_budget_handler);

    // Internal endpoint for bot heartbeats
    r.post("/v1/internal/bots/heartbeat", heartbeat_handler);

    return 0;
}

fn check_operator(c: zokor.Ctx[app.App]) -> bool {
    let account_id = c.local("account_id");
    let is_admin = app.has_role(c.state, account_id, "admin");
    if let a = is_admin { if a { return true; } }
    let is_treasury = app.has_role(c.state, account_id, "treasury");
    if let t = is_treasury { if t { return true; } }
    let is_super = app.has_role(c.state, account_id, "super_admin");
    if let s = is_super { if s { return true; } }
    return false;
}

fn get_summary_handler(c: zokor.Ctx[app.App]) -> http.Response {
    if !check_operator(c) {
        return zokor.respond(c.errors, "treasury.forbidden", c.request_id);
    }
    let season_id = c.query("season");
    let res = treasury_svc.get_summary(c.state.treasury, season_id);
    guard let sum = res else let e = err_of(res) {
        c.state.settings.server.logger.error("treasury", "summary failed: " + e);
        return zokor.respond(c.errors, "treasury.unavailable", c.request_id);
    }
    return zokor.no_store(zokor.ok_json(summary_json(sum).render()));
}

fn list_bots_handler(c: zokor.Ctx[app.App]) -> http.Response {
    if !check_operator(c) {
        return zokor.respond(c.errors, "treasury.forbidden", c.request_id);
    }
    let res = treasury_svc.list_bots(c.state.treasury);
    guard let bots = res else let e = err_of(res) {
        c.state.settings.server.logger.error("treasury", "list bots failed: " + e);
        return zokor.respond(c.errors, "treasury.unavailable", c.request_id);
    }
    let arr = zokor.jarr();
    for b in bots {
        arr.add(bot_overview_json(b));
    }
    return zokor.no_store(zokor.ok_json(arr.render()));
}

fn list_decisions_handler(c: zokor.Ctx[app.App]) -> http.Response {
    if !check_operator(c) {
        return zokor.respond(c.errors, "treasury.forbidden", c.request_id);
    }
    let bot_id = c.param("bot_id");
    let market_id = c.param("market_id");
    let limit = c.query_int("limit", 50);
    let res = treasury_svc.list_decisions(c.state.treasury, bot_id, market_id, limit);
    guard let decs = res else let e = err_of(res) {
        c.state.settings.server.logger.error("treasury", "list decisions failed: " + e);
        return zokor.respond(c.errors, "treasury.unavailable", c.request_id);
    }
    let arr = zokor.jarr();
    for d in decs {
        arr.add(decision_json(d));
    }
    return zokor.no_store(zokor.ok_json(arr.render()));
}

fn pause_bot_handler(c: zokor.Ctx[app.App]) -> http.Response {
    if !check_operator(c) {
        return zokor.respond(c.errors, "treasury.forbidden", c.request_id);
    }
    let bot_id = c.param("bot_id");
    let market_id = c.param("market_id");
    let dr: result[PauseReasonDto, http.Response] = zokor.dto(c);
    let reason = "manual pause";
    if let body = dr {
        if len(body.reason) > 0 { reason = body.reason; }
    }
    let res = treasury_svc.pause_bot(c.state.treasury, bot_id, market_id, reason);
    guard let _ok = res else let e = err_of(res) {
        c.state.settings.server.logger.error("treasury", "pause bot failed: " + e);
        return zokor.respond(c.errors, "treasury.unavailable", c.request_id);
    }
    return zokor.ok_json("{\"ok\":true}");
}

fn resume_bot_handler(c: zokor.Ctx[app.App]) -> http.Response {
    if !check_operator(c) {
        return zokor.respond(c.errors, "treasury.forbidden", c.request_id);
    }
    let bot_id = c.param("bot_id");
    let market_id = c.param("market_id");
    let dr: result[PauseReasonDto, http.Response] = zokor.dto(c);
    let reason = "manual resume";
    if let body = dr {
        if len(body.reason) > 0 { reason = body.reason; }
    }
    let res = treasury_svc.resume_bot(c.state.treasury, bot_id, market_id, reason);
    guard let _ok = res else let e = err_of(res) {
        c.state.settings.server.logger.error("treasury", "resume bot failed: " + e);
        return zokor.respond(c.errors, "treasury.unavailable", c.request_id);
    }
    return zokor.ok_json("{\"ok\":true}");
}

fn pause_all_handler(c: zokor.Ctx[app.App]) -> http.Response {
    if !check_operator(c) {
        return zokor.respond(c.errors, "treasury.forbidden", c.request_id);
    }
    let dr: result[PauseReasonDto, http.Response] = zokor.dto(c);
    let reason = "global pause";
    if let body = dr {
        if len(body.reason) > 0 { reason = body.reason; }
    }
    let res = treasury_svc.pause_all_bots(c.state.treasury, reason);
    guard let _ok = res else let e = err_of(res) {
        c.state.settings.server.logger.error("treasury", "pause all failed: " + e);
        return zokor.respond(c.errors, "treasury.unavailable", c.request_id);
    }
    return zokor.ok_json("{\"ok\":true}");
}

fn resume_all_handler(c: zokor.Ctx[app.App]) -> http.Response {
    if !check_operator(c) {
        return zokor.respond(c.errors, "treasury.forbidden", c.request_id);
    }
    let dr: result[PauseReasonDto, http.Response] = zokor.dto(c);
    let reason = "global resume";
    if let body = dr {
        if len(body.reason) > 0 { reason = body.reason; }
    }
    let res = treasury_svc.resume_all_bots(c.state.treasury, reason);
    guard let _ok = res else let e = err_of(res) {
        c.state.settings.server.logger.error("treasury", "resume all failed: " + e);
        return zokor.respond(c.errors, "treasury.unavailable", c.request_id);
    }
    return zokor.ok_json("{\"ok\":true}");
}

fn patch_params_handler(c: zokor.Ctx[app.App]) -> http.Response {
    if !check_operator(c) {
        return zokor.respond(c.errors, "treasury.forbidden", c.request_id);
    }
    let bot_id = c.param("bot_id");
    let market_id = c.param("market_id");
    let dr: result[PatchParamsRequestDto, http.Response] = zokor.dto(c);
    guard let body = dr else let bad = err_of(dr) {
        return bad;
    }
    let bp = body.params;
    let params = domain.BotParams {
        base_spread_ticks: bp.base_spread_ticks,
        vol_ticks: bp.vol_ticks,
        skew_ticks: bp.skew_ticks,
        levels: bp.levels,
        base_size: bp.base_size,
        max_net_shares: bp.max_net_shares,
        max_loss: bp.max_loss,
        season_max_drawdown: bp.season_max_drawdown,
        min_requote_ms: bp.min_requote_ms,
        max_ops_per_sec: bp.max_ops_per_sec,
        max_open_orders: bp.max_open_orders
    };
    let res = treasury_svc.patch_params(c.state.treasury, bot_id, market_id, params, c.local("account_id"), body.version);
    guard let new_ver = res else let e = err_of(res) {
        return zokor.respond(c.errors, "treasury.bad_request", c.request_id);
    }
    return zokor.ok_json("{\"version\":" + to_str(new_ver) + "}");
}

fn topup_handler(c: zokor.Ctx[app.App]) -> http.Response {
    if !check_operator(c) {
        return zokor.respond(c.errors, "treasury.forbidden", c.request_id);
    }
    let bot_id = c.param("bot_id");
    let market_id = c.param("market_id");
    let dr: result[TopupDto, http.Response] = zokor.dto(c);
    guard let body = dr else let bad = err_of(dr) {
        return bad;
    }
    let res = treasury_svc.topup_budget(c.state.treasury, "", bot_id, market_id, body.amount, c.local("account_id"), body.reason);
    guard let _ok = res else let e = err_of(res) {
        if e == "BUDGET_CAP_EXCEEDED" {
            return zokor.respond(c.errors, "treasury.budget_cap_exceeded", c.request_id);
        }
        return zokor.respond(c.errors, "treasury.unavailable", c.request_id);
    }
    return zokor.ok_json("{\"ok\":true}");
}

fn season_budget_handler(c: zokor.Ctx[app.App]) -> http.Response {
    if !check_operator(c) {
        return zokor.respond(c.errors, "treasury.forbidden", c.request_id);
    }
    let dr: result[SeasonBudgetDto, http.Response] = zokor.dto(c);
    guard let body = dr else let bad = err_of(dr) {
        return bad;
    }
    let res = treasury_svc.propose_season_budget(c.state.treasury, body.season, body.amount, c.local("account_id"), body.reason);
    guard let appr_id = res else let e = err_of(res) {
        return zokor.respond(c.errors, "treasury.unavailable", c.request_id);
    }
    return zokor.created("{\"approval_id\":\"" + appr_id + "\"}", "/v1/admin/approvals/" + appr_id);
}

fn heartbeat_handler(c: zokor.Ctx[app.App]) -> http.Response {
    let dr: result[HeartbeatDto, http.Response] = zokor.dto(c);
    guard let body = dr else let bad = err_of(dr) {
        return bad;
    }
    let payload = domain.HeartbeatPayload {
        bot_id: body.bot_id,
        market_id: body.market_id,
        status: body.status,
        status_reason: body.status_reason,
        holding_yes: body.holding_yes,
        holding_no: body.holding_no,
        used: body.used,
        spread_ticks: body.spread_ticks
    };
    let res = treasury_svc.record_heartbeat(c.state.treasury, payload);
    guard let _ok = res else let e = err_of(res) {
        c.state.settings.server.logger.warn("treasury", "heartbeat error: " + e);
        return zokor.respond(c.errors, "treasury.unavailable", c.request_id);
    }
    return zokor.ok_json("{\"ok\":true}");
}

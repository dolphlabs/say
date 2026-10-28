
fn json_resp(j: zokor.Json) -> http.Response {
    return zokor.no_store(zokor.ok_json(j.render()));
}

// zokor:public
import "http";
import "strings";
import "time";
import "timez";
import "zokor";
import "../../platform/app" as app;
import "../../platform/auth" as auth;
import "../domain" as domain;
import "../service" as res_svc;

pub fn mount(r: zokor.Router[app.App]) -> int {
    zokor.register(r.errors, "BAD_REQUEST", 400, "Check your request parameters.");
    zokor.register(r.errors, "FORBIDDEN", 403, "You do not have permission to perform this action.");
    zokor.register(r.errors, "NOT_FOUND", 404, "Market or resource not found.");
    zokor.register(r.errors, "WINDOW_OPEN", 409, "Dispute window is still open.");
    zokor.register(r.errors, "DISPUTES_UNDECIDED", 409, "All disputes must be decided before finalizing.");
    zokor.register(r.errors, "PROPOSER_CANNOT_FINALIZE", 403, "The proposer cannot finalize their own proposal.");
    zokor.register(r.errors, "NOT_SUPER_ADMIN", 403, "Only a super admin can finalize or decide disputes.");
    zokor.register(r.errors, "STALE_VERSION", 409, "The resolution record was modified by another operator.");
    zokor.register(r.errors, "NO_EVIDENCE", 400, "At least one evidence item is required to propose.");
    zokor.register(r.errors, "INVALID_STATE", 409, "Action is not allowed in current resolution state.");
    zokor.register(r.errors, "VOID_NEEDS_SECOND_APPROVAL", 409, "Void shortfall over S 50,000 requires second approval.");
    zokor.register(r.errors, "ALREADY_DISPUTED", 409, "You have already raised a dispute for this market.");
    zokor.register(r.errors, "NOT_ELIGIBLE_TO_DISPUTE", 403, "Only holders or former holders can dispute this market.");
    zokor.register(r.errors, "INVALID_REASON_LENGTH", 400, "Dispute reason must be between 20 and 500 characters.");
    zokor.register(r.errors, "UNAVAILABLE", 503, "Service temporarily unavailable.");

    // Admin routes
    let adm = r.group("/v1/admin");
    adm.before(auth.require_session);

    adm.get("/resolutions", get_queue_handler);
    adm.get("/resolutions/{market_id}", get_resolution_detail_handler);
    adm.post("/resolutions/{market_id}/evidence", post_evidence_handler);
    adm.post("/resolutions/{market_id}/evidence/refresh", post_refresh_evidence_handler);
    adm.post("/resolutions/{market_id}/propose", post_propose_handler);
    adm.post("/resolutions/{market_id}/hold", post_hold_handler);
    adm.post("/resolutions/{market_id}/disputes/{id}/decide", post_decide_dispute_handler);
    adm.post("/resolutions/{market_id}/finalize", post_finalize_handler);
    adm.get("/settlements/{market_id}", get_settlement_progress_handler);

    // Public resolution routes
    r.get("/v1/markets/{market_id}/resolution", get_public_resolution_handler);

    // Public dispute route (authenticated)
    let mkt_user = r.group("/v1/markets");
    mkt_user.before(auth.require_session);
    mkt_user.post("/{market_id}/disputes", post_dispute_handler);

    return 0;
}

fn get_actor(c: zokor.Ctx[app.App]) -> res_svc.Actor {
    let account_id = c.local("account_id");
    let roles: [str] = [];
    let is_sup = app.has_role(c.state, account_id, "super_admin");
    if let sup = is_sup {
        if sup { push(roles, "super_admin"); }
    }
    let is_res = app.has_role(c.state, account_id, "resolver");
    if let res = is_res {
        if res { push(roles, "resolver"); }
    }
    return res_svc.Actor { id: account_id, roles: roles };
}

fn get_queue_handler(c: zokor.Ctx[app.App]) -> http.Response {
    let state_filter = c.query("state");
    let qr = res_svc.get_queue(c.state.resolution, state_filter);
    guard let items = qr else let e = err_of(qr) {
        return zokor.respond(c.errors, "UNAVAILABLE", c.request_id);
    }

    let arr = zokor.jarr();
    for it in items {
        arr.add(zokor.jobj()
            .set_str("market_id", it.market_id)
            .set_str("slug", it.slug)
            .set_str("question", it.question)
            .set_str("state", it.state)
            .set_str("stage_label", it.stage_label)
            .set_str("meta", it.meta)
            .set_bool("conflict", it.conflict)
            .set_bool("overdue", it.overdue));
    }
    return json_resp(arr);
}

fn get_resolution_detail_handler(c: zokor.Ctx[app.App]) -> http.Response {
    let market_id = c.param("market_id");
    let dr = res_svc.get_resolution_detail(c.state.resolution, market_id);
    guard let d = dr else let e = err_of(dr) {
        if e == "NOT_FOUND" {
            return zokor.respond(c.errors, "NOT_FOUND", c.request_id);
        }
        return zokor.respond(c.errors, "UNAVAILABLE", c.request_id);
    }

    let ev_arr = zokor.jarr();
    for ev in d.evidence {
        ev_arr.add(zokor.jobj()
            .set_str("id", ev.id)
            .set_str("source_id", ev.source_id)
            .set_str("url", ev.url)
            .set_str("retrieved_at", ev.retrieved_at.rfc3339())
            .set_int("http_status", ev.http_status)
            .set_str("content_type", ev.content_type)
            .set_str("snapshot_ref", ev.snapshot_ref)
            .set_str("sha256", ev.sha256)
            .set_str("finding", ev.finding)
            .set_str("verdict", ev.verdict)
            .set_str("collected_by", ev.collected_by));
    }

    let disp_arr = zokor.jarr();
    for dp in d.disputes {
        disp_arr.add(zokor.jobj()
            .set_str("id", dp.id)
            .set_str("account_id", dp.account_id)
            .set_str("proposal_id", dp.proposal_id)
            .set_str("holdings_proof", dp.holdings_proof)
            .set_str("reason", dp.reason)
            .set_str("link_url", dp.link_url)
            .set_str("decision", dp.decision)
            .set_str("decision_note", dp.decision_note)
            .set_str("decided_by", dp.decided_by)
            .set_str("decided_at", dp.decided_at)
            .set_str("created_at", dp.created_at.rfc3339()));
    }

    let preview_obj = zokor.jobj()
        .set_str("outcome", d.preview.outcome)
        .set_int("winners", d.preview.winners)
        .set_int("payout_total", d.preview.payout_total)
        .set_int("burned_yes", d.preview.burned_yes)
        .set_int("burned_no", d.preview.burned_no)
        .set_int("collateral_released", d.preview.collateral_released)
        .set_int("refunds_total", d.preview.refunds_total)
        .set_int("fee_refunds_total", d.preview.fee_refunds_total)
        .set_int("treasury_delta", d.preview.treasury_delta)
        .set_int("shortfall", d.preview.shortfall)
        .set_bool("needs_second_approval", d.preview.needs_second_approval);

    let res_obj = zokor.jobj()
        .set_str("market_id", d.market_id)
        .set_str("slug", d.slug)
        .set_str("question", d.question)
        .set_str("state", d.state)
        .set_int("version", d.version)
        .set_bool("conflict", d.conflict)
        .set_bool("overdue", d.overdue)
        .set_str("dispute_until", d.dispute_until)
        .set_str("proposed_outcome", d.proposed_outcome)
        .set_str("proposed_reason", d.proposed_reason)
        .set_str("hold_reason", d.hold_reason)
        .set_str("final_outcome", d.final_outcome)
        .set_str("final_reason", d.final_reason)
        .set_str("decided_at", d.decided_at)
        .set("evidence", ev_arr)
        .set("disputes", disp_arr)
        .set("preview", preview_obj);

    return json_resp(res_obj);
}

fn post_evidence_handler(c: zokor.Ctx[app.App]) -> http.Response {
    let market_id = c.param("market_id");
    let dr: result[AddEvidenceDto, http.Response] = zokor.dto(c);
    guard let dto = dr else let err_resp = err_of(dr) { return err_resp; }

    let note = "";
    if let n = dto.note { note = n; }

    let actor = get_actor(c);
    let r = res_svc.add_evidence(c.state.resolution, market_id, dto.url, note, actor);
    guard let ev_id = r else let e = err_of(r) {
        if e == "FORBIDDEN" { return zokor.respond(c.errors, "FORBIDDEN", c.request_id); }
        return zokor.respond(c.errors, "BAD_REQUEST", c.request_id);
    }

    return json_resp(zokor.jobj().set_str("evidence_id", ev_id));
}

fn post_refresh_evidence_handler(c: zokor.Ctx[app.App]) -> http.Response {
    let market_id = c.param("market_id");
    let actor = get_actor(c);
    let r = res_svc.refresh_evidence(c.state.resolution, market_id, actor);
    guard let _ok = r else let e = err_of(r) {
        if e == "FORBIDDEN" { return zokor.respond(c.errors, "FORBIDDEN", c.request_id); }
        return zokor.respond(c.errors, "BAD_REQUEST", c.request_id);
    }
    return json_resp(zokor.jobj().set_bool("ok", true));
}

fn post_propose_handler(c: zokor.Ctx[app.App]) -> http.Response {
    let market_id = c.param("market_id");
    let dr: result[ProposeDto, http.Response] = zokor.dto(c);
    guard let dto = dr else let err_resp = err_of(dr) { return err_resp; }

    let actor = get_actor(c);
    let r = res_svc.propose(c.state.resolution, market_id, dto.outcome, dto.reason, dto.evidence_ids, dto.version, actor);
    guard let _ok = r else let e = err_of(r) {
        if e == "FORBIDDEN" { return zokor.respond(c.errors, "FORBIDDEN", c.request_id); }
        if e == "NO_EVIDENCE" { return zokor.respond(c.errors, "NO_EVIDENCE", c.request_id); }
        if e == "STALE_VERSION" { return zokor.respond(c.errors, "STALE_VERSION", c.request_id); }
        return zokor.respond(c.errors, "BAD_REQUEST", c.request_id);
    }
    return json_resp(zokor.jobj().set_bool("ok", true));
}

fn post_hold_handler(c: zokor.Ctx[app.App]) -> http.Response {
    let market_id = c.param("market_id");
    let dr: result[HoldDto, http.Response] = zokor.dto(c);
    guard let dto = dr else let err_resp = err_of(dr) { return err_resp; }

    let actor = get_actor(c);
    let r = res_svc.hold(c.state.resolution, market_id, dto.reason, dto.version, actor);
    guard let _ok = r else let e = err_of(r) {
        if e == "FORBIDDEN" { return zokor.respond(c.errors, "FORBIDDEN", c.request_id); }
        if e == "STALE_VERSION" { return zokor.respond(c.errors, "STALE_VERSION", c.request_id); }
        return zokor.respond(c.errors, "BAD_REQUEST", c.request_id);
    }
    return json_resp(zokor.jobj().set_bool("ok", true));
}

fn post_decide_dispute_handler(c: zokor.Ctx[app.App]) -> http.Response {
    let market_id = c.param("market_id");
    let dispute_id = c.param("id");
    let dr: result[DecideDisputeDto, http.Response] = zokor.dto(c);
    guard let dto = dr else let err_resp = err_of(dr) { return err_resp; }

    let actor = get_actor(c);
    let r = res_svc.decide_dispute(c.state.resolution, market_id, dispute_id, dto.decision, dto.note, actor);
    guard let _ok = r else let e = err_of(r) {
        if e == "NOT_SUPER_ADMIN" { return zokor.respond(c.errors, "NOT_SUPER_ADMIN", c.request_id); }
        return zokor.respond(c.errors, "BAD_REQUEST", c.request_id);
    }
    return json_resp(zokor.jobj().set_bool("ok", true));
}

fn post_finalize_handler(c: zokor.Ctx[app.App]) -> http.Response {
    let market_id = c.param("market_id");
    let dr: result[FinalizeDto, http.Response] = zokor.dto(c);
    guard let dto = dr else let err_resp = err_of(dr) { return err_resp; }

    let vr = "";
    if let v = dto.void_reason { vr = v; }

    let actor = get_actor(c);
    let r = res_svc.finalize(c.state.resolution, market_id, dto.outcome, vr, dto.reason, dto.version, actor);
    guard let res = r else let e = err_of(r) {
        if e == "NOT_SUPER_ADMIN" { return zokor.respond(c.errors, "NOT_SUPER_ADMIN", c.request_id); }
        if strings.has_prefix(e, "WINDOW_OPEN") { return zokor.respond(c.errors, "WINDOW_OPEN", c.request_id); }
        if e == "PROPOSER_CANNOT_FINALIZE" { return zokor.respond(c.errors, "PROPOSER_CANNOT_FINALIZE", c.request_id); }
        if e == "DISPUTES_UNDECIDED" { return zokor.respond(c.errors, "DISPUTES_UNDECIDED", c.request_id); }
        if e == "STALE_VERSION" { return zokor.respond(c.errors, "STALE_VERSION", c.request_id); }
        if e == "VOID_NEEDS_SECOND_APPROVAL" { return zokor.respond(c.errors, "VOID_NEEDS_SECOND_APPROVAL", c.request_id); }
        return zokor.respond(c.errors, "BAD_REQUEST", c.request_id);
    }

    return json_resp(zokor.jobj()
        .set_str("status", res.status)
        .set_str("outcome", res.outcome)
        .set_str("dispute_until", res.dispute_until)
        .set_str("message", res.message));
}

fn get_settlement_progress_handler(c: zokor.Ctx[app.App]) -> http.Response {
    let market_id = c.param("market_id");
    let r = res_svc.get_settlement_progress(c.state.resolution, market_id);
    guard let sp = r else let e = err_of(r) {
        if e == "NOT_FOUND" { return zokor.respond(c.errors, "NOT_FOUND", c.request_id); }
        return zokor.respond(c.errors, "UNAVAILABLE", c.request_id);
    }

    return json_resp(zokor.jobj()
        .set_str("market_id", sp.market_id)
        .set_str("decision_id", sp.decision_id)
        .set_str("state", sp.state)
        .set_int("cursor", sp.cursor)
        .set_bool("done", sp.done)
        .set_int("winners_count", sp.winners_count)
        .set_int("payout_total", sp.payout_total)
        .set_int("refunds_total", sp.refunds_total)
        .set_int("fee_refunds_total", sp.fee_refunds_total)
        .set_int("collateral_released", sp.collateral_released)
        .set_int("treasury_delta", sp.treasury_delta)
        .set_int("shortfall", sp.shortfall)
        .set_str("error_message", sp.error_message));
}

fn get_public_resolution_handler(c: zokor.Ctx[app.App]) -> http.Response {
    let market_id = c.param("market_id");
    let r = res_svc.get_public_resolution(c.state.resolution, market_id);
    guard let pub_res = r else let e = err_of(r) {
        return zokor.respond(c.errors, "NOT_FOUND", c.request_id);
    }

    let ev_arr = zokor.jarr();
    for ev in pub_res.evidence {
        ev_arr.add(zokor.jobj()
            .set_str("source", ev.source)
            .set_str("finding", ev.finding)
            .set_str("verdict", ev.verdict)
            .set_str("retrieved_at", ev.retrieved_at)
            .set_str("snapshot_url", ev.snapshot_url)
            .set_str("sha256", ev.sha256));
    }

    let fin_obj = zokor.jobj();
    let has_final = len(pub_res.final_outcome) > 0;
    if has_final {
        fin_obj = zokor.jobj()
            .set_str("outcome", pub_res.final_outcome)
            .set_str("reason", pub_res.final_reason)
            .set_str("decided_at", pub_res.decided_at);
    }

    let obj = zokor.jobj()
        .set_str("state", pub_res.state)
        .set_str("proposed_outcome", pub_res.proposed_outcome)
        .set_str("dispute_until", pub_res.dispute_until)
        .set("evidence", ev_arr);

    if has_final {
        obj.set("final", fin_obj);
    }

    return json_resp(obj);
}

fn post_dispute_handler(c: zokor.Ctx[app.App]) -> http.Response {
    let market_id = c.param("market_id");
    let dr: result[CreateDisputeDto, http.Response] = zokor.dto(c);
    guard let dto = dr else let err_resp = err_of(dr) { return err_resp; }

    let link_url = "";
    if let lu = dto.link_url { link_url = lu; }

    let account_id = c.local("account_id");
    let r = res_svc.dispute(c.state.resolution, market_id, dto.reason, link_url, account_id);
    guard let disp_id = r else let e = err_of(r) {
        if strings.has_prefix(e, "INVALID_REASON_LENGTH") { return zokor.respond(c.errors, "INVALID_REASON_LENGTH", c.request_id); }
        if e == "ALREADY_DISPUTED" { return zokor.respond(c.errors, "ALREADY_DISPUTED", c.request_id); }
        if e == "NOT_ELIGIBLE_TO_DISPUTE" { return zokor.respond(c.errors, "NOT_ELIGIBLE_TO_DISPUTE", c.request_id); }
        if e == "DISPUTE_WINDOW_CLOSED" { return zokor.respond(c.errors, "WINDOW_OPEN", c.request_id); }
        return zokor.respond(c.errors, "INVALID_STATE", c.request_id);
    }

    return json_resp(zokor.jobj().set_str("dispute_id", disp_id));
}

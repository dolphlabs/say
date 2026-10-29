// zokor:public
import "http";
import "time";
import "zokor";
import "../../platform/app" as app;
import "../../platform/auth" as auth;
import "../domain" as domain;
import "../service" as service;

pub fn mount(r: zokor.Router[app.App]) -> int {
    register_errors(r.errors);

    let adm = r.group("/v1/admin/approvals");
    adm.before(auth.require_session);

    adm.get("", list_approvals_handler);
    adm.post("/:id/approve", approve_handler);
    adm.post("/:id/reject", reject_handler);

    return 0;
}

fn register_errors(e: zokor.Registry) {
    zokor.register(e, "approvals.forbidden", 403, "Forbidden: caller cannot decide this approval.");
    zokor.register(e, "approvals.self_approval", 403, "You asked for this, so someone else has to approve it.");
    zokor.register(e, "approvals.stale", 409, "Approval request payload hash does not match or request expired.");
    zokor.register(e, "approvals.not_found", 404, "Approval request not found.");
    zokor.register(e, "approvals.totp_required", 403, "Recent TOTP 2FA verification required for staff approval actions.");
    zokor.register(e, "approvals.unavailable", 503, "Approvals service temporarily unavailable.");
}

gc struct DecisionDto {
    payload_hash: str,
    note: opt[str],
    reason: opt[str]
}

fn check_totp_recent(c: zokor.Ctx[app.App], account_id: str) -> bool {
    return auth.has_recent_totp(c, account_id);
}

fn list_approvals_handler(c: zokor.Ctx[app.App]) -> http.Response {
    let account_id = c.local("account_id");
    let status_filter = c.query("status");
    let kind_filter = c.query("kind");

    let list_res = service.list_inbox(c.state.approvals, status_filter, kind_filter);
    guard let items = list_res else let e = err_of(list_res) {
        c.state.settings.server.logger.error("approvals", "list_inbox: " + e);
        return zokor.respond(c.errors, "approvals.unavailable", c.request_id);
    }

    let items_arr = zokor.jarr();
    for it in items {
        let is_requester = (it.requester_account_id == account_id);
        let can_decide = it.can_decide;
        let reason = it.cannot_decide_reason;
        if is_requester {
            can_decide = false;
            reason = "You asked for this, so someone else has to approve it.";
        }

        let obj = zokor.jobj()
            .set_str("id", it.id)
            .set_str("kind", it.kind)
            .set_str("title", it.title)
            .set_str("detail", it.detail)
            .set("requested_by", zokor.jobj()
                .set_str("username", it.requested_by.username)
                .set_str("role", it.requested_by.role))
            .set_int("requested_at", it.requested_at)
            .set_bool("can_decide", can_decide)
            .set_str("subject_link", it.subject_link)
            .set_str("payload_hash", it.payload_hash)
            .set_str("status", it.status);
        if !can_decide {
            obj.set_str("cannot_decide_reason", reason);
        }
        items_arr.add(obj);
    }

    let out = zokor.jobj().set("items", items_arr);
    return zokor.no_store(zokor.ok_json(out.render()));
}

fn approve_handler(c: zokor.Ctx[app.App]) -> http.Response {
    let approval_id = c.param("id");
    let account_id = c.local("account_id");

    if !check_totp_recent(c, account_id) {
        return zokor.respond(c.errors, "approvals.totp_required", c.request_id);
    }

    let dr: result[DecisionDto, http.Response] = zokor.dto(c);
    guard let body = dr else let bad = err_of(dr) { return bad; }

    let load_res = service.load_by_id(c.state.approvals, approval_id);
    guard let opt_req = load_res else let e = err_of(load_res) {
        return zokor.respond(c.errors, "approvals.unavailable", c.request_id);
    }

    guard let req = opt_req else {
        return zokor.respond(c.errors, "approvals.not_found", c.request_id);
    }

    if req.requested_by == account_id {
        return zokor.respond(c.errors, "approvals.self_approval", c.request_id);
    }

    if req.payload_hash != body.payload_hash {
        return zokor.respond(c.errors, "approvals.stale", c.request_id);
    }

    let now_ms = (time.mono() / 1000000) as int;
    let note = "";
    if let n = body.note { note = n; }

    let dec_res = service.decide(c.state.approvals, req, account_id, "approved", note, now_ms);
    guard let _ok = dec_res else let e = err_of(dec_res) {
        if e == "SELF_APPROVAL_FORBIDDEN" {
            return zokor.respond(c.errors, "approvals.self_approval", c.request_id);
        }
        if e == "STALE_APPROVAL" {
            return zokor.respond(c.errors, "approvals.stale", c.request_id);
        }
        c.state.settings.server.logger.error("approvals", "decide approved: " + e);
        return zokor.respond(c.errors, "approvals.unavailable", c.request_id);
    }

    return zokor.no_store(zokor.ok_json("{\"status\":\"approved\"}"));
}

fn reject_handler(c: zokor.Ctx[app.App]) -> http.Response {
    let approval_id = c.param("id");
    let account_id = c.local("account_id");

    if !check_totp_recent(c, account_id) {
        return zokor.respond(c.errors, "approvals.totp_required", c.request_id);
    }

    let dr: result[DecisionDto, http.Response] = zokor.dto(c);
    guard let body = dr else let bad = err_of(dr) { return bad; }

    let load_res = service.load_by_id(c.state.approvals, approval_id);
    guard let opt_req = load_res else let e = err_of(load_res) {
        return zokor.respond(c.errors, "approvals.unavailable", c.request_id);
    }

    guard let req = opt_req else {
        return zokor.respond(c.errors, "approvals.not_found", c.request_id);
    }

    if req.requested_by == account_id {
        return zokor.respond(c.errors, "approvals.self_approval", c.request_id);
    }

    if req.payload_hash != body.payload_hash {
        return zokor.respond(c.errors, "approvals.stale", c.request_id);
    }

    let now_ms = (time.mono() / 1000000) as int;
    let reason = "";
    if let r = body.reason { reason = r; }

    let dec_res = service.decide(c.state.approvals, req, account_id, "rejected", reason, now_ms);
    guard let _ok = dec_res else let e = err_of(dec_res) {
        if e == "SELF_APPROVAL_FORBIDDEN" {
            return zokor.respond(c.errors, "approvals.self_approval", c.request_id);
        }
        if e == "STALE_APPROVAL" {
            return zokor.respond(c.errors, "approvals.stale", c.request_id);
        }
        c.state.settings.server.logger.error("approvals", "decide rejected: " + e);
        return zokor.respond(c.errors, "approvals.unavailable", c.request_id);
    }

    return zokor.no_store(zokor.ok_json("{\"status\":\"rejected\"}"));
}

// zokor:public
import "http";
import "strconv";
import "zokor";
import "../../platform/app" as app;
import "../../platform/auth" as auth;
import "../domain" as domain;
import "../service" as audit_svc;

pub fn mount(r: zokor.Router[app.App]) -> int {
    register_errors(r.errors);

    let adm = r.group("/v1/admin/audit");
    adm.before(auth.require_session);

    adm.get("", query_audit_handler);
    adm.post("/export", export_audit_handler);
    adm.get("/export/:id", download_export_handler);

    return 0;
}

fn register_errors(e: zokor.ErrorRegistry) {
    zokor.register_error(e, "audit.forbidden", 403, "FORBIDDEN", "Forbidden: caller cannot access audit logs.");
    zokor.register_error(e, "audit.not_found", 404, "NOT_FOUND", "Audit export not found or expired.");
    zokor.register_error(e, "audit.unavailable", 503, "UNAVAILABLE", "Audit service temporarily unavailable.");
}

fn parse_int_or(s: str, default_val: int) -> int {
    if s == "" { return default_val; }
    let p = strconv.parse_int(s);
    if let v = p { return v; }
    return default_val;
}

fn check_staff(c: zokor.Ctx[app.App]) -> bool {
    let account_id = c.local("account_id");
    let is_admin = app.has_role(c.state, account_id, "admin");
    if let a = is_admin { if a { return true; } }
    let is_super = app.has_role(c.state, account_id, "super_admin");
    if let s = is_super { if s { return true; } }
    let is_treasury = app.has_role(c.state, account_id, "treasury");
    if let t = is_treasury { if t { return true; } }
    return false;
}

fn query_audit_handler(c: zokor.Ctx[app.App]) -> http.Response {
    if !check_staff(c) {
        return zokor.respond(c.errors, "audit.forbidden", c.request_id);
    }

    let filter = domain.AuditFilter {
        area: c.query("area"),
        actor: c.query("actor"),
        target_type: c.query("target_type"),
        target_id: c.query("target_id"),
        from_ms: parse_int_or(c.query("from"), 0),
        to_ms: parse_int_or(c.query("to"), 0),
        cursor: c.query("cursor"),
        limit: parse_int_or(c.query("limit"), 50)
    };

    let res = audit_svc.get_audit_log(c.state.audit, filter);
    guard let page = res else let e = err_of(res) {
        c.state.settings.server.logger.error("audit", "query failed: " + e);
        return zokor.respond(c.errors, "audit.unavailable", c.request_id);
    }

    let items_arr = zokor.jarr();
    for it in page.items {
        items_arr.add_obj(zokor.jobj()
            .set_str("id", it.id)
            .set_str("actor_id", it.actor_id)
            .set_str("actor_kind", it.actor_kind)
            .set_str("role_at_time", it.role_at_time)
            .set_str("area", it.area)
            .set_str("action", it.action)
            .set_str("target_type", it.target_type)
            .set_str("target_id", it.target_id)
            .set_str("ip_address", it.ip_address)
            .set_int("created_at", it.created_at_ms));
    }

    let out = zokor.jobj()
        .set_arr("items", items_arr)
        .set_str("next_cursor", page.next_cursor);

    return zokor.no_store(zokor.ok_json(out.render()));
}

fn export_audit_handler(c: zokor.Ctx[app.App]) -> http.Response {
    if !check_staff(c) {
        return zokor.respond(c.errors, "audit.forbidden", c.request_id);
    }

    let account_id = c.local("account_id");
    let base_url = c.state.settings.server.base_url;

    let filter = domain.AuditFilter {
        area: c.query("area"),
        actor: c.query("actor"),
        target_type: c.query("target_type"),
        target_id: c.query("target_id"),
        from_ms: parse_int_or(c.query("from"), 0),
        to_ms: parse_int_or(c.query("to"), 0),
        cursor: "",
        limit: 1000
    };

    let res = audit_svc.export_audit_csv(c.state.audit, account_id, filter, base_url);
    guard let job = res else let e = err_of(res) {
        c.state.settings.server.logger.error("audit", "export failed: " + e);
        return zokor.respond(c.errors, "audit.unavailable", c.request_id);
    }

    let out = zokor.jobj()
        .set_str("export_id", job.id)
        .set_str("status", job.status)
        .set_str("download_url", job.download_url);

    return zokor.no_store(zokor.ok_json(out.render()));
}

fn download_export_handler(c: zokor.Ctx[app.App]) -> http.Response {
    if !check_staff(c) {
        return zokor.respond(c.errors, "audit.forbidden", c.request_id);
    }

    let export_id = c.param("id");
    let res = audit_svc.download_csv(c.state.audit, export_id);
    guard let opt_csv = res else let e = err_of(res) {
        c.state.settings.server.logger.error("audit", "download failed: " + e);
        return zokor.respond(c.errors, "audit.unavailable", c.request_id);
    }

    guard let csv = opt_csv else {
        return zokor.respond(c.errors, "audit.not_found", c.request_id);
    }

    let resp = zokor.no_store(zokor.ok_text(csv));
    resp.headers["Content-Type"] = "text/csv";
    resp.headers["Content-Disposition"] = "attachment; filename=\"audit_export.csv\"";
    return resp;
}

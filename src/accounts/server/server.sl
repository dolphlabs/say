// zokor:public
import "http";
import "strings";
import "zokor";
import "../../platform/app" as app;
import "../service" as accounts;

pub fn mount(r: zokor.Router[app.App]) -> int {
    register_errors(r.errors);
    let g = r.group("/v1/accounts");
    g.get("/check-username", check_username_availability);
    g.post("", register_account);
    g.get("", list_accounts);
    g.get("/:id", show_account);
    return 0;
}

fn tenant(c: zokor.Ctx[app.App]) -> str {
    let t = c.local("tenant_id");
    if t != "" {
        return t;
    }
    let h = c.header("x-tenant-id");
    if h != "" {
        return h;
    }
    return "default";
}

fn extract_client_meta(c: zokor.Ctx[app.App]) -> accounts.AuditMeta {
    let xff = c.header("x-forwarded-for");
    let xri = c.header("x-real-ip");
    let ip = "";
    if xff != "" {
        let ips = strings.split(xff, ",");
        if len(ips) > 0 {
            ip = strings.trim(ips[0]);
        }
    } else if xri != "" {
        ip = strings.trim(xri);
    }

    let ua = c.header("user-agent");
    let lang = c.header("accept-language");
    let sec_ua = c.header("sec-ch-ua");
    let sec_plat = c.header("sec-ch-ua-platform");
    let sec_mob = c.header("sec-ch-ua-mobile");
    let ref = c.header("referer");
    let orig = c.header("origin");
    let fp = c.header("x-device-fingerprint");

    let detail = zokor.jobj()
        .set_str("ip", ip)
        .set_str("user_agent", ua)
        .set_str("accept_language", lang)
        .set_str("sec_ch_ua", sec_ua)
        .set_str("sec_ch_ua_platform", sec_plat)
        .set_str("sec_ch_ua_mobile", sec_mob)
        .set_str("referer", ref)
        .set_str("origin", orig)
        .set_str("signup_channel", "WEB")
        .render();

    let ip_opt: opt[str] = none;
    if ip != "" {
        ip_opt = some(ip);
    }
    let ua_opt: opt[str] = none;
    if ua != "" {
        ua_opt = some(ua);
    }
    let fp_opt: opt[str] = none;
    if fp != "" {
        fp_opt = some(fp);
    }

    return accounts.AuditMeta {
        ip_address: ip_opt,
        user_agent: ua_opt,
        fingerprint: fp_opt,
        detail_json: detail
    };
}

fn check_username_availability(c: zokor.Ctx[app.App]) -> http.Response {
    let u = c.query("username");
    if u == "" {
        return zokor.respond_fields(c.errors, "validation_failed",
            [zokor.field("username", "must not be empty")], c.request_id);
    }
    let r = accounts.check_username(c.state.accounts, tenant(c), u);
    guard let _avail = r else let f = err_of(r) {
        return failure(c, f);
    }
    return zokor.ok_json(username_available_json(u, true));
}

fn register_account(c: zokor.Ctx[app.App]) -> http.Response {
    let dr: result[RegisterAccountDto, http.Response] = zokor.dto(c);
    guard let body = dr else let bad = err_of(dr) {
        return bad;
    }
    let meta = extract_client_meta(c);
    let made = accounts.create_with_password(c.state.accounts, tenant(c), body.username, body.email, body.password, body.phone_number, meta);
    guard let n = made else let f = err_of(made) {
        return failure(c, f);
    }
    return zokor.created(account_json(n).render(), "/v1/accounts/" + n.id);
}

fn show_account(c: zokor.Ctx[app.App]) -> http.Response {
    let found = accounts.get(c.state.accounts, tenant(c), c.param("id"));
    guard let n = found else let f = err_of(found) {
        return failure(c, f);
    }
    return zokor.ok_json(account_json(n).render());
}

fn list_accounts(c: zokor.Ctx[app.App]) -> http.Response {
    let offset = c.query_int("offset", 0);
    let limit = c.query_int("limit", 50);
    if limit < 1 || limit > 100 || offset < 0 {
        return zokor.respond_fields(c.errors, "validation_failed",
            [zokor.field("limit", "must be 1-100, with offset 0 or more")], c.request_id);
    }
    let rows = accounts.list(c.state.accounts, tenant(c), offset, limit);
    guard let ns = rows else let f = err_of(rows) {
        return failure(c, f);
    }
    return zokor.ok_json(accounts_json(ns));
}

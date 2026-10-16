import "http";
import "zokor";
import "../../platform/app" as app;
import "../../platform/auth" as auth;
import "../service" as accounts;

pub fn mount(r: zokor.Router[app.App]) -> int {
    register_errors(r.errors);
    let g = r.group("/accounts");
    g.before(auth.require_tenant);
    g.post("", create_account);
    g.get("", list_accounts);
    g.get("/:id", show_account);
    return 0;
}

fn create_account(c: zokor.Ctx[app.App]) -> http.Response {
    let dr: result[NewAccountDto, http.Response] = zokor.dto(c);
    guard let body = dr else let bad = err_of(dr) {
        return bad;
    }
    let provider = body.auth_provider ?? "LOCAL";
    let none_str: opt[str] = none;
    let made = accounts.create(c.state.accounts, c.local("tenant_id"), body.email, none_str, provider);
    guard let n = made else let f = err_of(made) {
        return failure(c, f);
    }
    return zokor.created(account_json(n).render(), "/accounts/" + n.id);
}

fn show_account(c: zokor.Ctx[app.App]) -> http.Response {
    let found = accounts.get(c.state.accounts, c.local("tenant_id"), c.param("id"));
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
    let rows = accounts.list(c.state.accounts, c.local("tenant_id"), offset, limit);
    guard let ns = rows else let f = err_of(rows) {
        return failure(c, f);
    }
    return zokor.ok_json(accounts_json(ns));
}

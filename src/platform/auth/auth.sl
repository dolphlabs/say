import "http";
import "zokor";
import "../app" as app;

pub fn require_tenant(c: zokor.Ctx[app.App]) -> opt[http.Response] {
    guard let tenant_id = zokor.api_key_client(c, c.state.settings.api_keys) else {
        return some(zokor.respond(c.errors, "unauthorized", c.request_id));
    }
    c.set_local("tenant_id", tenant_id);
    return none;
}

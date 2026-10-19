import "encoding";
import "zokor";
import "../../platform/app" as app;
import "../service" as accounts;

// The session auth.require_session resolved for this request.
fn session(c: zokor.Ctx[app.App]) -> accounts.Session {
    return accounts.Session {
        account_id: c.local("account_id"),
        token_hash: encoding.hex_decode(c.local("session_hash")) ?? b""
    };
}

fn meta(c: zokor.Ctx[app.App]) -> accounts.Meta {
    return accounts.Meta { ip: c.client_ip, user_agent: c.header("user-agent") };
}

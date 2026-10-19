import "http";
import "zokor";
import "../app" as app;

pub fn cookie_name() -> str {
    return "say_session";
}

// The cookie first, then `Authorization: Bearer` for mobile clients.
pub fn session_token(c: zokor.Ctx[app.App]) -> str {
    let from_cookie = c.cookie(cookie_name());
    if len(from_cookie) > 0 {
        return from_cookie;
    }
    return c.bearer();
}

// Sets the locals account_id and session_hash for the handler.
pub fn require_session(c: zokor.Ctx[app.App]) -> opt[http.Response] {
    let r = app.authenticate(c.state, session_token(c));
    guard let found = r else let e = err_of(r) {
        c.state.settings.server.logger.error("auth", "session lookup failed: " + e);
        return some(zokor.respond(c.errors, "UNAVAILABLE", c.request_id));
    }
    guard let caller = found else {
        return some(zokor.respond(c.errors, "UNAUTHENTICATED", c.request_id));
    }
    c.set_local("account_id", caller.account_id);
    c.set_local("session_hash", caller.session_hash);
    return none;
}

pub fn session_cookie(token: str, max_age_seconds: int) -> zokor.Cookie {
    let ck = zokor.new_cookie(cookie_name(), token);
    ck.path = "/";
    ck.http_only = true;
    ck.secure = true;
    ck.same_site = zokor.SameSite.LAX;
    ck.max_age = max_age_seconds;
    return ck;
}

pub fn with_session(resp: http.Response, token: str) -> result[http.Response, str] {
    return zokor.set_cookie(resp, session_cookie(token, 2592000));
}

pub fn without_session(resp: http.Response) -> http.Response {
    return zokor.clear_cookie(resp, cookie_name(), "/", "") ?? resp;
}

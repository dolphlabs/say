import "http";
import "jwt";
import "time";
import "zokor";
import "../app" as app;

pub gc struct SessionClaims {
    sub: str,
    email: str,
    username: str,
    kind: str,
    iat: int,
    exp: int
}

pub fn require_tenant(c: zokor.Ctx[app.App]) -> opt[http.Response] {
    guard let tenant_id = zokor.api_key_client(c, c.state.settings.api_keys) else {
        return some(zokor.respond(c.errors, "unauthorized", c.request_id));
    }
    c.set_local("tenant_id", tenant_id);
    return none;
}

pub fn issue_session_cookie(account_id: str, email: str, username: str, kind: str, jwt_auth: zokor.JwtAuth, cookie_keys: zokor.CookieKeys) -> result[zokor.Cookie, str] {
    let now_s = time.wall() / 1000000000;
    let max_age_s = 604800; // 7 days
    let claims = SessionClaims {
        sub: account_id,
        email: email,
        username: username,
        kind: kind,
        iat: now_s,
        exp: now_s + max_age_s
    };
    let token_res = zokor.sign_token(claims, jwt_auth);
    guard let token = token_res else let e = err_of(token_res) {
        return err(e);
    }
    let c_res = zokor.signed_cookie("say_session", token, cookie_keys);
    guard let c = c_res else let e = err_of(c_res) {
        return err(e);
    }
    c.path = "/";
    c.http_only = true;
    c.same_site = zokor.SameSite.LAX;
    c.max_age = max_age_s;
    return ok(c);
}

pub fn current_session(c: zokor.Ctx[app.App]) -> opt[SessionClaims] {
    let none_claims: opt[SessionClaims] = none;
    let raw_opt = zokor.signed_value(c, "say_session", c.state.settings.cookie_keys);
    guard let token = raw_opt else {
        return none_claims;
    }
    let now_s = time.wall() / 1000000000;
    let prob = zokor.token_problem(token, c.state.settings.jwt_auth, now_s);
    if len(prob) > 0 {
        return none_claims;
    }
    if len(c.state.settings.jwt_auth.keys) == 0 {
        return none_claims;
    }
    let verified: result[SessionClaims, str] = jwt.verify(token, c.state.settings.jwt_auth.keys[0]);
    guard let claims = verified else {
        return none_claims;
    }
    return some(claims);
}

pub fn require_session(c: zokor.Ctx[app.App]) -> opt[http.Response] {
    guard let claims = current_session(c) else {
        return some(zokor.respond(c.errors, "unauthorized", c.request_id));
    }
    c.set_local("account_id", claims.sub);
    c.set_local("username", claims.username);
    c.set_local("email", claims.email);
    c.set_local("kind", claims.kind);
    return none;
}

// zokor:public
import "encoding";
import "http";
import "timez";
import "zokor";
import "../../platform/app" as app;
import "../../platform/auth" as auth;
import "../domain" as domain;
import "../service" as accounts;

// /v1/auth/* is public by design (it is how a caller gets a session);
// /v1/me/* and logout-others sit behind auth.require_session.
pub fn mount(r: zokor.Router[app.App]) -> int {
    register_errors(r.errors);
    let g = r.group("/v1/auth");
    g.get("/username/:name", check_username);
    g.post("/username/hold", hold_username);
    g.post("/signup", signup);
    g.post("/otp/resend", resend);
    g.post("/otp/verify", verify);
    g.post("/login", login);
    g.get("/google/start", google_start);
    g.get("/google/callback", google_callback);
    g.post("/google/complete", google_complete);
    g.post("/logout", logout);
    g.post("/password/forgot", forgot);
    g.post("/password/reset", reset);
    let signed = r.group("/v1/auth");
    signed.before(auth.require_session);
    signed.post("/logout-others", logout_others);
    let me = r.group("/v1/me");
    me.before(auth.require_session);
    me.get("", show_me);
    me.post("/password", change_password);
    me.delete("/google", unlink_google);
    me.delete("", delete_me);
    return 0;
}

fn signed_in(c: zokor.Ctx[app.App], status: i32, s: accounts.SignedIn) -> http.Response {
    let body = zokor.jobj()
        .set("user", user_json(s.account, changeable_at(s.account, s.grant)))
        .set("grant", grant_json(s.grant))
        .render();
    let resp = zokor.no_store(zokor.json_response(status, body));
    let cr = auth.with_session(resp, s.session_token);
    guard let with_cookie = cr else let e = err_of(cr) {
        c.state.settings.server.logger.error("accounts", "session cookie refused: " + e);
        return zokor.respond(c.errors, "UNAVAILABLE", c.request_id);
    }
    return with_cookie;
}

fn check_username(c: zokor.Ctx[app.App]) -> http.Response {
    let r = accounts.check_username(c.state.accounts, c.param("name"), c.client_ip);
    guard let u = r else let f = err_of(r) {
        return failure(c, f);
    }
    let sugg = zokor.jarr();
    for s in u.suggestions {
        sugg.add_str(s);
    }
    let body = zokor.jobj().set_str("username", u.username).set_bool("available", u.available);
    if len(u.reason) > 0 {
        body.set_str("reason", u.reason);
    }
    return zokor.ok_json(body.set("suggestions", sugg).render());
}

fn hold_username(c: zokor.Ctx[app.App]) -> http.Response {
    let dr: result[HoldDto, http.Response] = zokor.dto(c);
    guard let body = dr else let bad = err_of(dr) {
        return bad;
    }
    let r = accounts.hold_username(c.state.accounts, body.username, c.client_ip);
    guard let h = r else let f = err_of(r) {
        return failure(c, f);
    }
    return zokor.ok_json(zokor.jobj()
        .set_str("username", h.username)
        .set_str("hold_id", h.hold_id)
        .set_str("expires_at", h.expires_at.rfc3339())
        .render());
}

fn signup(c: zokor.Ctx[app.App]) -> http.Response {
    let dr: result[SignupDto, http.Response] = zokor.dto(c);
    guard let body = dr else let bad = err_of(dr) {
        return bad;
    }
    let r = accounts.signup(c.state.accounts, c.state.mailer, body.username, body.hold_id, body.email,
                            body.password, meta(c));
    guard let s = r else let fs = err_of(r) {
        return failures(c, fs);
    }
    return zokor.no_store(zokor.json_response(201, zokor.jobj()
        .set_str("signup_token", s.signup_token)
        .set_str("email_masked", s.email_masked)
        .set_str("resend_available_at", s.resend_available_at.rfc3339())
        .render()));
}

fn resend(c: zokor.Ctx[app.App]) -> http.Response {
    let dr: result[ResendDto, http.Response] = zokor.dto(c);
    guard let body = dr else let bad = err_of(dr) {
        return bad;
    }
    let r = accounts.resend(c.state.accounts, c.state.mailer, body.signup_token ?? "", body.email ?? "",
                            body.purpose, meta(c));
    guard let q = r else let f = err_of(r) {
        return failure(c, f);
    }
    return zokor.accepted(zokor.jobj().set_str("resend_available_at", q.resend_available_at.rfc3339()).render());
}

fn verify(c: zokor.Ctx[app.App]) -> http.Response {
    let dr: result[VerifyDto, http.Response] = zokor.dto(c);
    guard let body = dr else let bad = err_of(dr) {
        return bad;
    }
    let r = accounts.verify_signup(c.state.accounts, body.signup_token, body.code, meta(c));
    guard let s = r else let f = err_of(r) {
        return failure(c, f);
    }
    return signed_in(c, 200, s);
}

fn login(c: zokor.Ctx[app.App]) -> http.Response {
    let dr: result[LoginDto, http.Response] = zokor.dto(c);
    guard let body = dr else let bad = err_of(dr) {
        return bad;
    }
    let r = accounts.login(c.state.accounts, body.email, body.password, meta(c));
    guard let s = r else let f = err_of(r) {
        return failure(c, f);
    }
    return signed_in(c, 200, s);
}

fn session_account(c: zokor.Ctx[app.App]) -> str {
    let r = accounts.authenticate(c.state.accounts, auth.session_token(c));
    if let found = r {
        if let s = found {
            return s.account_id;
        }
    }
    return "";
}

fn google_start(c: zokor.Ctx[app.App]) -> http.Response {
    let intent = c.query("intent");
    if len(intent) == 0 {
        intent = "login";
    }
    let account = "";
    if intent == "link" {
        account = session_account(c);
    }
    let r = accounts.google_start(c.state.accounts, intent, account);
    guard let url = r else let f = err_of(r) {
        return failure(c, f);
    }
    return zokor.no_store(zokor.redirect(302, url));
}

fn to_app(c: zokor.Ctx[app.App], path: str) -> http.Response {
    return zokor.no_store(zokor.redirect(302, c.state.settings.auth.app_url + path));
}

// The browser arrives here from Google, so every outcome is a redirect
// back into the app, errors included, as ?error=<CODE>.
fn google_callback(c: zokor.Ctx[app.App]) -> http.Response {
    let err_param = c.query("error");
    if len(err_param) > 0 {
        return to_app(c, "/login?error=GOOGLE_FAILED");
    }
    let r = accounts.google_callback(c.state.accounts, c.query("state"), c.query("code"), meta(c));
    guard let cb = r else let f = err_of(r) {
        log_hidden(c, f);
        return to_app(c, "/login?error=" + code_of(f.why));
    }
    switch cb.kind {
        case accounts.CallbackKind.SignedIn {
            let resp = to_app(c, "/");
            return auth.with_session(resp, cb.session_token) ?? resp;
        }
        case accounts.CallbackKind.Linked {
            return to_app(c, "/settings?google=linked");
        }
        default {
            return to_app(c, "/signup/google?pending_token=" + encoding.url_encode(cb.pending_token) +
                          "&email=" + encoding.url_encode(cb.email_masked));
        }
    }
}

fn google_complete(c: zokor.Ctx[app.App]) -> http.Response {
    let dr: result[GoogleCompleteDto, http.Response] = zokor.dto(c);
    guard let body = dr else let bad = err_of(dr) {
        return bad;
    }
    let r = accounts.google_complete(c.state.accounts, body.pending_token, body.username, body.hold_id, meta(c));
    guard let s = r else let f = err_of(r) {
        return failure(c, f);
    }
    return signed_in(c, 200, s);
}

// Idempotent: no session or an already-revoked one still answers 204 and
// clears the cookie.
fn logout(c: zokor.Ctx[app.App]) -> http.Response {
    let r = accounts.authenticate(c.state.accounts, auth.session_token(c));
    if let found = r {
        if let s = found {
            let lr = accounts.logout(c.state.accounts, s, meta(c));
            guard let _ok = lr else let f = err_of(lr) {
                return failure(c, f);
            }
        }
    }
    return auth.without_session(zokor.no_content());
}

fn logout_others(c: zokor.Ctx[app.App]) -> http.Response {
    let r = accounts.logout_others(c.state.accounts, session(c), meta(c));
    guard let _n = r else let f = err_of(r) {
        return failure(c, f);
    }
    return zokor.no_content();
}

fn forgot(c: zokor.Ctx[app.App]) -> http.Response {
    let dr: result[ForgotDto, http.Response] = zokor.dto(c);
    guard let body = dr else let bad = err_of(dr) {
        return bad;
    }
    if let limited = accounts.forgot_password(c.state.accounts, c.state.mailer, body.email, meta(c)) {
        return failure(c, limited);
    }
    return zokor.accepted("{}");
}

fn reset(c: zokor.Ctx[app.App]) -> http.Response {
    let dr: result[ResetDto, http.Response] = zokor.dto(c);
    guard let body = dr else let bad = err_of(dr) {
        return bad;
    }
    let r = accounts.reset_password(c.state.accounts, body.email, body.code, body.new_password, meta(c));
    guard let _n = r else let f = err_of(r) {
        return failure(c, f);
    }
    return auth.without_session(zokor.no_content());
}

fn load_account(s: app.App, id: str) -> result[domain.Account, accounts.Failed] {
    return accounts.account_of(s.accounts, id);
}

fn load_season_end(s: app.App) -> result[opt[timez.Time], str] {
    return app.current_season_end(s);
}

// The account and the season are independent reads: both go at once.
fn show_me(c: zokor.Ctx[app.App]) -> http.Response {
    let id = c.local("account_id");
    let ah = spawn load_account(c.state, id);
    let sh = spawn load_season_end(c.state);
    let aj = join_wait(ah);
    let sj = join_wait(sh);
    guard let ar = aj else let e = err_of(aj) {
        c.state.settings.server.logger.error("accounts", "me: " + e);
        return zokor.respond(c.errors, "UNAVAILABLE", c.request_id);
    }
    guard let account = ar else let f = err_of(ar) {
        return failure(c, f);
    }
    let changeable = account.username_changeable_at;
    if let sr = sj {
        if let season_r = sr {
            if let ends_at = season_r {
                if ends_at.after(changeable) {
                    changeable = ends_at;
                }
            }
        }
    }
    return zokor.no_store(zokor.ok_json(user_json(account, changeable).render()));
}

fn change_password(c: zokor.Ctx[app.App]) -> http.Response {
    let dr: result[ChangePasswordDto, http.Response] = zokor.dto(c);
    guard let body = dr else let bad = err_of(dr) {
        return bad;
    }
    let r = accounts.change_password(c.state.accounts, session(c), body.current_password, body.new_password, meta(c));
    guard let _n = r else let f = err_of(r) {
        return failure(c, f);
    }
    return zokor.no_content();
}

fn unlink_google(c: zokor.Ctx[app.App]) -> http.Response {
    let r = accounts.unlink_google(c.state.accounts, session(c), meta(c));
    guard let _ok = r else let f = err_of(r) {
        return failure(c, f);
    }
    return zokor.no_content();
}

fn delete_me(c: zokor.Ctx[app.App]) -> http.Response {
    let r = accounts.delete_account(c.state.accounts, session(c), meta(c));
    guard let _ok = r else let f = err_of(r) {
        return failure(c, f);
    }
    return auth.without_session(zokor.accepted("{}"));
}

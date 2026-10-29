// zokor:public
import "crypto";
import "encoding";
import "http";
import "time";
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
    me.post("/username", change_username);
    me.post("/email", request_email_change);
    me.post("/email/verify", verify_email_change);
    me.post("/password", change_password);
    me.delete("/google", unlink_google);
    me.post("/2fa/enroll", enroll_2fa);
    me.post("/2fa/verify", verify_2fa);
    me.post("/2fa/disable", disable_2fa);
    me.delete("", delete_me);

    let adm = r.group("/v1/admin");
    adm.before(auth.require_session);
    adm.post("/roles", grant_role_handler);
    adm.delete("/roles", revoke_role_handler);

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
    let account_id = c.local("account_id");

    // 1. Cancel all open orders concurrently across markets
    let m_res = accounts.open_markets_for_account(c.state.accounts, account_id);
    if let markets_list = m_res {
        for m_id in markets_list {
            let _ = app.cancel_all_orders_for_market(c.state, m_id, account_id, app.new_uuid());
        }
    }

    // 2. Anonymise account everywhere
    let anon_res = accounts.anonymise_account(c.state.accounts, account_id);
    guard let _ok = anon_res else let e = err_of(anon_res) {
        c.state.settings.server.logger.error("accounts", "anonymise failed: " + e);
        return zokor.respond(c.errors, "UNAVAILABLE", c.request_id);
    }

    return auth.without_session(zokor.accepted("{}"));
}

fn change_username(c: zokor.Ctx[app.App]) -> http.Response {
    let dr: result[ChangeUsernameDto, http.Response] = zokor.dto(c);
    guard let body = dr else let bad = err_of(dr) { return bad; }

    let account_id = c.local("account_id");

    // Check target availability and format
    let chk = accounts.check_username(c.state.accounts, body.username, c.client_ip);
    guard let u = chk else let f = err_of(chk) { return failure(c, f); }
    if !u.available {
        return zokor.respond(c.errors, "USERNAME_TAKEN", c.request_id);
    }

    // Get old username
    let acc_r = accounts.account_of(c.state.accounts, account_id);
    guard let opt_acc = acc_r else let _f = err_of(acc_r) {
        return zokor.respond(c.errors, "UNAVAILABLE", c.request_id);
    }
    let old_username = opt_acc.username;

    let now_ms = (time.mono() / 1000000) as int;
    let chg_r = accounts.change_username(c.state.accounts, account_id, old_username, body.username, now_ms);
    guard let _ok = chg_r else let e = err_of(chg_r) {
        if e == "USERNAME_CHANGE_WINDOW_CLOSED" {
            return zokor.respond(c.errors, "USERNAME_CHANGE_WINDOW_CLOSED", c.request_id);
        }
        if e == "USERNAME_ALREADY_CHANGED_THIS_SEASON" {
            return zokor.respond(c.errors, "USERNAME_ALREADY_CHANGED_THIS_SEASON", c.request_id);
        }
        return zokor.respond(c.errors, "UNAVAILABLE", c.request_id);
    }

    return zokor.ok_json("{\"username\":\"" + body.username + "\"}");
}

fn request_email_change(c: zokor.Ctx[app.App]) -> http.Response {
    let dr: result[RequestEmailChangeDto, http.Response] = zokor.dto(c);
    guard let body = dr else let bad = err_of(dr) { return bad; }

    let account_id = c.local("account_id");

    let req_r = accounts.request_email_change(c.state.accounts, account_id, body.new_email);
    guard let req = req_r else let e = err_of(req_r) {
        return zokor.respond(c.errors, "UNAVAILABLE", c.request_id);
    }

    let send_mail = c.state.mailer.send;
    let _s = send_mail(c.state.mailer.context, accounts.Mail {
        to: body.new_email,
        username: "",
        purpose: "change_email",
        code: req.code
    });

    let resp_body = zokor.jobj()
        .set_str("change_token", req.token)
        .set_str("resend_available_at", "60s")
        .render();
    return zokor.no_store(zokor.json_response(202, resp_body));
}

fn verify_email_change(c: zokor.Ctx[app.App]) -> http.Response {
    let dr: result[VerifyEmailChangeDto, http.Response] = zokor.dto(c);
    guard let body = dr else let bad = err_of(dr) { return bad; }

    let account_id = c.local("account_id");

    let ver_r = accounts.verify_email_change(c.state.accounts, account_id, body.change_token, body.code);
    guard let res = ver_r else let e = err_of(ver_r) {
        if e == "INVALID_CODE" {
            return zokor.respond(c.errors, "INVALID_CODE", c.request_id);
        }
        return zokor.respond(c.errors, "UNAVAILABLE", c.request_id);
    }

    if res.old_email != "" {
        let send_mail = c.state.mailer.send;
        let _s = send_mail(c.state.mailer.context, accounts.Mail {
            to: res.old_email,
            username: "",
            purpose: "security_notice",
            code: ""
        });
    }

    return zokor.no_content();
}

fn enroll_2fa(c: zokor.Ctx[app.App]) -> http.Response {
    let account_id = c.local("account_id");

    let acc_r = accounts.account_of(c.state.accounts, account_id);
    guard let opt_acc = acc_r else let _f = err_of(acc_r) {
        return zokor.respond(c.errors, "UNAVAILABLE", c.request_id);
    }
    let username = opt_acc.username;

    let enr_r = accounts.enroll_totp(c.state.accounts, account_id, username);
    guard let enr = enr_r else let e = err_of(enr_r) {
        return zokor.respond(c.errors, "UNAVAILABLE", c.request_id);
    }

    let body = zokor.jobj()
        .set_str("secret", enr.secret_b32)
        .set_str("uri", enr.uri)
        .render();
    return zokor.no_store(zokor.ok_json(body));
}

fn verify_2fa(c: zokor.Ctx[app.App]) -> http.Response {
    let dr: result[Verify2faDto, http.Response] = zokor.dto(c);
    guard let body = dr else let bad = err_of(dr) { return bad; }

    let account_id = c.local("account_id");
    let now_sec = (time.mono() / 1000000000) as int;
    let sess_token = auth.session_token(c);
    let sess_hash = encoding.hex_encode(crypto.sha256(to_bytes(sess_token)));

    let ver_r = accounts.verify_totp(c.state.accounts, account_id, sess_hash, body.code, now_sec);
    guard let _ok = ver_r else let e = err_of(ver_r) {
        if e == "INVALID_CODE" {
            return zokor.respond(c.errors, "INVALID_CODE", c.request_id);
        }
        return zokor.respond(c.errors, "UNAVAILABLE", c.request_id);
    }

    return zokor.ok_json("{\"verified\":true}");
}

fn disable_2fa(c: zokor.Ctx[app.App]) -> http.Response {
    let dr: result[Verify2faDto, http.Response] = zokor.dto(c);
    guard let body = dr else let bad = err_of(dr) { return bad; }

    let account_id = c.local("account_id");
    let now_sec = (time.mono() / 1000000000) as int;

    let dis_r = accounts.disable_totp(c.state.accounts, account_id, body.code, now_sec);
    guard let _ok = dis_r else let e = err_of(dis_r) {
        if e == "INVALID_CODE" {
            return zokor.respond(c.errors, "INVALID_CODE", c.request_id);
        }
        return zokor.respond(c.errors, "UNAVAILABLE", c.request_id);
    }

    return zokor.no_content();
}

fn grant_role_handler(c: zokor.Ctx[app.App]) -> http.Response {
    let caller_id = c.local("account_id");
    let dr: result[RoleAdminDto, http.Response] = zokor.dto(c);
    guard let body = dr else let bad = err_of(dr) { return bad; }

    let is_super = app.has_role(c.state, caller_id, "super_admin");
    let can_grant = false;
    if let s = is_super { if s { can_grant = true; } }
    if body.role == "creator" {
        let is_curator = app.has_role(c.state, caller_id, "curator");
        if let cu = is_curator { if cu { can_grant = true; } }
    }

    if !can_grant {
        return zokor.respond(c.errors, "FORBIDDEN", c.request_id);
    }

    let target_r = accounts.find_account_id_by_username(c.state.accounts, body.username);
    guard let opt_target = target_r else let e = err_of(target_r) {
        return zokor.respond(c.errors, "UNAVAILABLE", c.request_id);
    }
    guard let target_id = opt_target else {
        return zokor.respond(c.errors, "NOT_FOUND", c.request_id);
    }

    if body.role == "creator" {
        let gr_r = accounts.grant_role(c.state.accounts, target_id, "creator");
        guard let _ok = gr_r else let e = err_of(gr_r) {
            return zokor.respond(c.errors, "UNAVAILABLE", c.request_id);
        }
        return zokor.ok_json("{\"status\":\"granted\"}");
    }

    let now_ms = (time.mono() / 1000000) as int;
    let payload = zokor.jobj().set_str("username", body.username).set_str("role", body.role).set_str("reason", body.reason).render();
    let p_hash = encoding.hex_encode(crypto.sha256(to_bytes(payload)));

    let req_res = app.request_approval(c.state, "role_grant", "role", target_id, p_hash, caller_id, 1, 1, body.reason, now_ms);
    guard let app_id = req_res else let e = err_of(req_res) {
        return zokor.respond(c.errors, "UNAVAILABLE", c.request_id);
    }

    let resp_b = zokor.jobj()
        .set_str("status", "pending_approval")
        .set_str("approval_id", app_id)
        .render();
    return zokor.no_store(zokor.json_response(202, resp_b));
}

fn revoke_role_handler(c: zokor.Ctx[app.App]) -> http.Response {
    let caller_id = c.local("account_id");
    let dr: result[RoleAdminDto, http.Response] = zokor.dto(c);
    guard let body = dr else let bad = err_of(dr) { return bad; }

    let is_super = app.has_role(c.state, caller_id, "super_admin");
    let can_revoke = false;
    if let s = is_super { if s { can_revoke = true; } }
    if body.role == "creator" {
        let is_curator = app.has_role(c.state, caller_id, "curator");
        if let cu = is_curator { if cu { can_revoke = true; } }
    }

    if !can_revoke {
        return zokor.respond(c.errors, "FORBIDDEN", c.request_id);
    }

    let target_r = accounts.find_account_id_by_username(c.state.accounts, body.username);
    guard let opt_target = target_r else let e = err_of(target_r) {
        return zokor.respond(c.errors, "UNAVAILABLE", c.request_id);
    }
    guard let target_id = opt_target else {
        return zokor.no_content();
    }

    let rev_r = accounts.revoke_role(c.state.accounts, target_id, body.role);
    guard let _ok = rev_r else let e = err_of(rev_r) {
        return zokor.respond(c.errors, "UNAVAILABLE", c.request_id);
    }

    return zokor.no_content();
}

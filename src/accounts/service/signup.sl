import "timez";
import "../domain" as domain;
import "../../ledger/domain" as ledger;

pub gc struct SignupStarted {
    signup_token: str,
    email_masked: str,
    resend_available_at: timez.Time
}

pub gc struct SignedIn {
    account: domain.Account,
    session_token: str,
    grant: opt[ledger.Grant]
}

pub gc struct ResendQueued {
    resend_available_at: timez.Time
}

// Every field problem at once; the first one names the error code the UI
// shows, in the order the screens ask for them.
fn signup_problems(a_reserved: [str], username: str, email: str, password: str) -> [Failed] {
    let out: [Failed] = [];
    if let bad = username_failure(username, a_reserved) {
        push(out, bad);
    }
    if let p = domain.email_problem(email) {
        push(out, fail_field(Why.EmailInvalid, "email", p));
    }
    if let p = domain.password_problem(password) {
        push(out, fail_field(Why.WeakPassword, "password", p));
    }
    return out;
}

pub fn first_of(fs: [Failed]) -> Failed {
    return fs[0];
}

pub fn signup[C, M](a: Auth[C], m: Mailer[M], raw_username: str, hold_id: str, raw_email: str,
                    password: str, meta: Meta) -> result[SignupStarted, [Failed]] {
    if let limited = allow(a, rule_signup_ip(), meta.ip) {
        return err([limited]);
    }
    let username = domain.normalize_username(raw_username);
    let email = domain.normalize_email(raw_email);
    let problems = signup_problems(a.cfg.reserved, username, email, password);
    if len(problems) > 0 {
        return err(problems);
    }
    if let bad = hold_problem(a, username, hold_id) {
        return err([bad]);
    }
    let hr = hash_with(a.hasher, password);
    guard let pass_hash = hr else let e = err_of(hr) {
        return err([hash_failure(e)]);
    }
    let cr = new_code();
    guard let code = cr else let e = err_of(cr) {
        return err([fail(Why.Unavailable, e)]);
    }
    let tr = new_token();
    guard let token = tr else let e = err_of(tr) {
        return err([fail(Why.Unavailable, e)]);
    }
    let make_id = a.new_id;
    let account_id = make_id();
    let pr = otp_payload(a.cfg.otp_secret, email, username, domain.purpose_verify_email(), code);
    guard let payload = pr else let e = err_of(pr) {
        return err([fail(Why.Unavailable, e)]);
    }
    let create = a.store.create_signup;
    let made = create(a.store.context, NewSignup {
        account_id: account_id,
        username: username,
        email: email,
        password_hash: pass_hash,
        password_algo: password_algo(),
        password_params: password_params(),
        code_hmac: domain.code_hmac(a.cfg.otp_secret, domain.purpose_verify_email(), account_id, code),
        otp_ttl_seconds: domain.otp_ttl_seconds(),
        signup_token_hash: token.hash,
        signup_ttl_seconds: a.cfg.signup_ttl_seconds,
        outbox_payload: payload
    });
    guard let sent = made else let f = err_of(made) {
        return err([from_store(f)]);
    }
    spawn deliver_now(a, m, sent.outbox_id);
    release_hold(a, username);
    audit_event(a, account_id, "signup", meta, "{}");
    audit_event(a, account_id, "otp_sent", meta, "{\"purpose\":\"verify_email\"}");
    return ok(SignupStarted {
        signup_token: token.value,
        email_masked: domain.mask_email(email),
        resend_available_at: sent.resend_available_at
    });
}

fn pending_for[C](a: Auth[C], signup_token: str) -> result[Pending, Failed] {
    if len(signup_token) == 0 || len(signup_token) > 128 {
        return err(fail(Why.PendingExpired, "no signup token"));
    }
    let f = a.store.signup_account;
    let r = f(a.store.context, hash_token(signup_token));
    guard let found = r else let sf = err_of(r) {
        return err(from_store(sf));
    }
    guard let p = found else {
        return err(fail(Why.PendingExpired, "signup token unknown or expired"));
    }
    return ok(p);
}

fn queue_code[C, M](a: Auth[C], m: Mailer[M], account_id: str, email: str, username: str,
                    purpose: str) -> result[CodeSent, Failed] {
    let cr = new_code();
    guard let code = cr else let e = err_of(cr) {
        return err(fail(Why.Unavailable, e));
    }
    let pr = otp_payload(a.cfg.otp_secret, email, username, purpose, code);
    guard let payload = pr else let e = err_of(pr) {
        return err(fail(Why.Unavailable, e));
    }
    let replace = a.store.replace_code;
    let r = replace(a.store.context, NewCode {
        account_id: account_id,
        email: email,
        purpose: purpose,
        code_hmac: domain.code_hmac(a.cfg.otp_secret, purpose, account_id, code),
        otp_ttl_seconds: domain.otp_ttl_seconds(),
        outbox_payload: payload,
        cooldown_seconds: domain.resend_cooldown_seconds(),
        max_per_hour: domain.max_sends_per_hour()
    });
    guard let sent = r else let f = err_of(r) {
        return err(from_store(f));
    }
    spawn deliver_now(a, m, sent.outbox_id);
    return ok(sent);
}

pub fn resend[C, M](a: Auth[C], m: Mailer[M], signup_token: str, raw_email: str, purpose: str,
                    meta: Meta) -> result[ResendQueued, Failed] {
    if let limited = allow(a, rule_recovery_ip(), meta.ip) {
        return err(limited);
    }
    if purpose == domain.purpose_verify_email() {
        let pr = pending_for(a, signup_token);
        guard let p = pr else let f = err_of(pr) {
            return err(f);
        }
        let qr = queue_code(a, m, p.account_id, p.email, p.username, purpose);
        guard let sent = qr else let f = err_of(qr) {
            return err(f);
        }
        audit_event(a, p.account_id, "otp_sent", meta, "{\"purpose\":\"verify_email\"}");
        return ok(ResendQueued { resend_available_at: sent.resend_available_at });
    }
    if purpose == domain.purpose_reset_password() {
        return ok(start_reset(a, m, raw_email, meta));
    }
    return err(fail_field(Why.BadRequest, "purpose", "must be verify_email or reset_password"));
}

// Always "queued": whether the email has an account is not the caller's
// business. The cooldown answer is the same either way.
fn start_reset[C, M](a: Auth[C], m: Mailer[M], raw_email: str, meta: Meta) -> ResendQueued {
    let later = ResendQueued { resend_available_at: timez.now().add(domain.resend_cooldown_seconds() * timez.SECOND) };
    let email = domain.normalize_email(raw_email);
    if let _p = domain.email_problem(email) {
        return later;
    }
    let find = a.store.find_login;
    let r = find(a.store.context, email);
    guard let found = r else let f = err_of(r) {
        report(a, "password reset lookup failed: " + f.detail);
        return later;
    }
    guard let row = found else {
        return later;
    }
    if row.status == domain.status_deleted() {
        return later;
    }
    let qr = queue_code(a, m, row.account_id, row.email, row.username, domain.purpose_reset_password());
    if let sent = qr {
        audit_event(a, row.account_id, "otp_sent", meta, "{\"purpose\":\"reset_password\"}");
        return ResendQueued { resend_available_at: sent.resend_available_at };
    }
    return later;
}

pub fn forgot_password[C, M](a: Auth[C], m: Mailer[M], raw_email: str, meta: Meta) -> opt[Failed] {
    if let limited = allow(a, rule_recovery_ip(), meta.ip) {
        return some(limited);
    }
    let _q = start_reset(a, m, raw_email, meta);
    return none;
}

fn code_failure(check: CodeCheck, attempts_left: int) -> Failed {
    switch check {
        case CodeCheck.Wrong {
            let f = fail_field(Why.OtpInvalid, "code", "is not right");
            f.attempts_left = attempts_left;
            return f;
        }
        case CodeCheck.Locked { return fail_field(Why.OtpLocked, "code", "too many attempts"); }
        default { return fail_field(Why.OtpExpired, "code", "has expired"); }
    }
}

fn new_session(token: Token, ttl: int, meta: Meta) -> NewSession {
    return NewSession { token_hash: token.hash, ttl_seconds: ttl, ip: meta.ip, user_agent: meta.user_agent };
}

pub fn verify_signup[C](a: Auth[C], signup_token: str, raw_code: str, meta: Meta) -> result[SignedIn, Failed] {
    if let limited = allow(a, rule_verify_ip(), meta.ip) {
        return err(limited);
    }
    let code = lower_trim(raw_code);
    if !domain.is_code_shape(code) {
        return err(fail_field(Why.OtpInvalid, "code", "must be 6 digits"));
    }
    let pr = pending_for(a, signup_token);
    guard let p = pr else let f = err_of(pr) {
        return err(f);
    }
    let tr = new_token();
    guard let token = tr else let e = err_of(tr) {
        return err(fail(Why.Unavailable, e));
    }
    let verify = a.store.verify_email;
    let r = verify(a.store.context, VerifyEmail {
        code: CodeUse {
            account_id: p.account_id,
            purpose: domain.purpose_verify_email(),
            code_hmac: domain.code_hmac(a.cfg.otp_secret, domain.purpose_verify_email(), p.account_id, code)
        },
        grant_amount: a.cfg.grant_amount,
        session: new_session(token, a.cfg.session_ttl_seconds, meta)
    });
    guard let v = r else let f = err_of(r) {
        return err(from_store(f));
    }
    if v.check != CodeCheck.Matched {
        audit_event(a, p.account_id, "otp_failed", meta, "{\"purpose\":\"verify_email\"}");
        return err(code_failure(v.check, v.attempts_left));
    }
    guard let account = v.account else {
        return err(fail(Why.Unavailable, "verified account not returned"));
    }
    audit_event(a, p.account_id, "email_verified", meta, "{}");
    return ok(SignedIn { account: account, session_token: token.value, grant: v.grant });
}

pub fn reset_password[C](a: Auth[C], raw_email: str, raw_code: str, new_password: str,
                         meta: Meta) -> result[int, Failed] {
    if let limited = allow(a, rule_recovery_ip(), meta.ip) {
        return err(limited);
    }
    if let p = domain.password_problem(new_password) {
        return err(fail_field(Why.WeakPassword, "new_password", p));
    }
    let code = lower_trim(raw_code);
    if !domain.is_code_shape(code) {
        return err(fail_field(Why.OtpInvalid, "code", "must be 6 digits"));
    }
    let email = domain.normalize_email(raw_email);
    let find = a.store.find_login;
    let fr = find(a.store.context, email);
    guard let found = fr else let f = err_of(fr) {
        return err(from_store(f));
    }
    let hr = hash_with(a.hasher, new_password);
    guard let pass_hash = hr else let e = err_of(hr) {
        return err(hash_failure(e));
    }
    guard let row = found else {
        return err(code_failure(CodeCheck.Missing, 0));
    }
    let reset = a.store.reset_password;
    let r = reset(a.store.context, ResetPassword {
        code: CodeUse {
            account_id: row.account_id,
            purpose: domain.purpose_reset_password(),
            code_hmac: domain.code_hmac(a.cfg.otp_secret, domain.purpose_reset_password(), row.account_id, code)
        },
        password_hash: pass_hash,
        password_algo: password_algo(),
        password_params: password_params()
    });
    guard let done = r else let f = err_of(r) {
        return err(from_store(f));
    }
    if done.check != CodeCheck.Matched {
        audit_event(a, row.account_id, "otp_failed", meta, "{\"purpose\":\"reset_password\"}");
        return err(code_failure(done.check, done.attempts_left));
    }
    forget_sessions(a, done.revoked);
    audit_event(a, row.account_id, "password_reset", meta, "{}");
    return ok(len(done.revoked));
}

import "http";
import "zokor";
import "../../platform/app" as app;
import "../service" as accounts;

fn register_errors(r: zokor.Registry) {
    zokor.register(r, "USERNAME_INVALID", 422, "Use 3-20 characters: a-z, 0-9, . and _.");
    zokor.register(r, "USERNAME_RESERVED", 422, "That username is reserved.");
    zokor.register(r, "USERNAME_TAKEN", 409, "That username is taken.");
    zokor.register(r, "USERNAME_HOLD_EXPIRED", 409, "Your username hold ran out. Pick it again.");
    zokor.register(r, "EMAIL_INVALID", 422, "That email address does not look right.");
    zokor.register(r, "EMAIL_IN_USE", 409, "That email already has an account. Log in instead.");
    zokor.register(r, "WEAK_PASSWORD", 422, "Use at least 8 characters.");
    zokor.register(r, "INVALID_CREDENTIALS", 401, "Email or password is wrong.");
    zokor.register(r, "EMAIL_NOT_VERIFIED", 403, "Verify your email to continue.");
    zokor.register(r, "OTP_INVALID", 400, "That code is not right.");
    zokor.register(r, "OTP_EXPIRED", 400, "That code has expired. Send a new one.");
    zokor.register(r, "OTP_LOCKED", 423, "Too many wrong codes. Send a new one.");
    zokor.register(r, "GOOGLE_EMAIL_IN_USE", 409, "That Google email already has an account. Log in with your password, then link Google in Settings.");
    zokor.register(r, "GOOGLE_LINKED_ELSEWHERE", 409, "That Google account is linked to another say account.");
    zokor.register(r, "GOOGLE_FAILED", 502, "Google sign-in did not work. Try again.");
    zokor.register(r, "PENDING_EXPIRED", 410, "That step expired. Start again.");
    zokor.register(r, "LAST_SIGN_IN_METHOD", 409, "Set a password before unlinking Google.");
}

fn code_of(why: accounts.Why) -> str {
    switch why {
        case accounts.Why.UsernameInvalid { return "USERNAME_INVALID"; }
        case accounts.Why.UsernameReserved { return "USERNAME_RESERVED"; }
        case accounts.Why.UsernameTaken { return "USERNAME_TAKEN"; }
        case accounts.Why.UsernameHoldExpired { return "USERNAME_HOLD_EXPIRED"; }
        case accounts.Why.EmailInvalid { return "EMAIL_INVALID"; }
        case accounts.Why.EmailInUse { return "EMAIL_IN_USE"; }
        case accounts.Why.WeakPassword { return "WEAK_PASSWORD"; }
        case accounts.Why.InvalidCredentials { return "INVALID_CREDENTIALS"; }
        case accounts.Why.EmailNotVerified { return "EMAIL_NOT_VERIFIED"; }
        case accounts.Why.OtpInvalid { return "OTP_INVALID"; }
        case accounts.Why.OtpExpired { return "OTP_EXPIRED"; }
        case accounts.Why.OtpLocked { return "OTP_LOCKED"; }
        case accounts.Why.GoogleEmailInUse { return "GOOGLE_EMAIL_IN_USE"; }
        case accounts.Why.GoogleLinkedElsewhere { return "GOOGLE_LINKED_ELSEWHERE"; }
        case accounts.Why.GoogleFailed { return "GOOGLE_FAILED"; }
        case accounts.Why.PendingExpired { return "PENDING_EXPIRED"; }
        case accounts.Why.LastSignInMethod { return "LAST_SIGN_IN_METHOD"; }
        case accounts.Why.RateLimited { return "RATE_LIMITED"; }
        case accounts.Why.Unauthenticated { return "UNAUTHENTICATED"; }
        case accounts.Why.BadRequest { return "BAD_REQUEST"; }
        case accounts.Why.Busy { return "BUSY"; }
        default { return "UNAVAILABLE"; }
    }
}

fn extras(f: accounts.Failed) -> [zokor.FieldError] {
    let out: [zokor.FieldError] = [];
    if f.retry_after > 0 {
        push(out, zokor.field("retry_after", to_str(f.retry_after)));
    }
    if f.attempts_left >= 0 {
        push(out, zokor.field("attempts_left", to_str(f.attempts_left)));
    }
    if len(f.signup_token) > 0 {
        push(out, zokor.field("signup_token", f.signup_token));
    }
    return out;
}

fn log_hidden(c: zokor.Ctx[app.App], f: accounts.Failed) {
    if f.why == accounts.Why.Unavailable || f.why == accounts.Why.GoogleFailed {
        c.state.settings.server.logger.error("accounts", code_of(f.why) + ": " + f.detail);
    }
}

fn failure(c: zokor.Ctx[app.App], f: accounts.Failed) -> http.Response {
    log_hidden(c, f);
    let fields = extras(f);
    if len(f.field) > 0 {
        push(fields, zokor.field(f.field, f.reason));
    }
    return zokor.respond_fields(c.errors, code_of(f.why), fields, c.request_id);
}

// Every field problem in one answer, under the first one's code.
fn failures(c: zokor.Ctx[app.App], fs: [accounts.Failed]) -> http.Response {
    let first = fs[0];
    log_hidden(c, first);
    let fields = extras(first);
    for f in fs {
        if len(f.field) > 0 {
            push(fields, zokor.field(f.field, f.reason));
        }
    }
    return zokor.respond_fields(c.errors, code_of(first.why), fields, c.request_id);
}

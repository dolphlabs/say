import "crypto";
import "encoding";
import "strings";
import "timez";
import "../domain" as domain;

pub enum Why {
    UsernameInvalid,
    UsernameReserved,
    UsernameTaken,
    UsernameHoldExpired,
    EmailInvalid,
    EmailInUse,
    WeakPassword,
    InvalidCredentials,
    EmailNotVerified,
    OtpInvalid,
    OtpExpired,
    OtpLocked,
    GoogleEmailInUse,
    GoogleLinkedElsewhere,
    GoogleFailed,
    PendingExpired,
    LastSignInMethod,
    RateLimited,
    Unauthenticated,
    BadRequest,
    Busy,
    Unavailable
}

pub gc struct Failed {
    why: Why,
    field: str,
    reason: str,
    retry_after: int,
    attempts_left: int,
    signup_token: str,
    detail: str
}

pub gc struct AuthConfig {
    otp_secret: bytes,
    reserved: [str],
    session_ttl_seconds: int,
    signup_ttl_seconds: int,
    hold_seconds: int,
    pending_seconds: int,
    oauth_state_seconds: int,
    google_client_id: str,
    google_redirect_uri: str,
    google_auth_url: str,
    dummy_hash: str
}

pub gc struct Meta {
    ip: str,
    user_agent: str
}

pub gc struct Auth[C] {
    store: AuthStore[C],
    settings: opt[SettingsStore[C]],
    cfg: AuthConfig,
    hasher: Hasher,
    audit: AuditLog,
    limiter: LocalLimiter,
    jwks: Jwks,
    problems: chan[str],
    new_id: fn() -> str
}

pub fn new_auth[C](store: AuthStore[C], cfg: AuthConfig, hasher: Hasher, new_id: fn() -> str) -> Auth[C] {
    let no_settings: opt[SettingsStore[C]] = none;
    return Auth[C] {
        store: store,
        settings: no_settings,
        cfg: cfg,
        hasher: hasher,
        audit: new_audit_log(4096),
        limiter: new_local_limiter(),
        jwks: new_jwks(),
        problems: make_chan(256),
        new_id: new_id
    };
}

pub fn with_settings[C](a: Auth[C], s: SettingsStore[C]) -> Auth[C] {
    a.settings = some(s);
    return a;
}

fn fail(why: Why, detail: str) -> Failed {
    return Failed { why: why, field: "", reason: "", retry_after: 0, attempts_left: -1, signup_token: "", detail: detail };
}

fn fail_field(why: Why, field: str, reason: str) -> Failed {
    return Failed { why: why, field: field, reason: reason, retry_after: 0, attempts_left: -1, signup_token: "", detail: reason };
}

fn fail_retry(why: Why, retry_after: int) -> Failed {
    let f = fail(why, "");
    f.retry_after = retry_after;
    return f;
}

fn from_store(f: StoreFail) -> Failed {
    switch f.fault {
        case Fault.UsernameTaken { return fail_field(Why.UsernameTaken, "username", "is taken"); }
        case Fault.EmailTaken { return fail_field(Why.EmailInUse, "email", "is already registered"); }
        case Fault.IdentityTaken { return fail(Why.GoogleLinkedElsewhere, f.detail); }
        case Fault.CoolingDown { return fail_retry(Why.RateLimited, f.retry_after); }
        case Fault.HourlyCap { return fail_retry(Why.RateLimited, f.retry_after); }
        case Fault.LastSignInMethod { return fail(Why.LastSignInMethod, f.detail); }
        case Fault.NotFound { return fail(Why.Unauthenticated, f.detail); }
        default { return fail(Why.Unavailable, f.detail); }
    }
}

// Background work reports here instead of logging: the service does no
// I/O, and platform/app drains the channel into the server's logger.
pub fn report[C](a: Auth[C], problem: str) {
    select {
        case chan_send(a.problems, problem) {}
        default {}
    }
}

pub gc struct Token {
    value: str,
    hash: bytes
}

pub fn hash_token(value: str) -> bytes {
    return crypto.sha256(to_bytes(value));
}

pub fn new_token() -> result[Token, str] {
    let r = crypto.rand(32);
    guard let b = r else let e = err_of(r) {
        return err(e);
    }
    let v = encoding.base64url_encode(b);
    return ok(Token { value: v, hash: hash_token(v) });
}

fn new_hex_id(n: int) -> result[str, str] {
    let r = crypto.rand(n);
    guard let b = r else let e = err_of(r) {
        return err(e);
    }
    return ok(encoding.hex_encode(b));
}

fn new_code() -> result[str, str] {
    for i in 0..8 {
        let r = crypto.rand(4);
        guard let b = r else let e = err_of(r) {
            return err(e);
        }
        if let code = domain.code_from(b) {
            return ok(code);
        }
    }
    return err("could not draw an unbiased code");
}

fn seconds_until(t: timez.Time) -> int {
    let d = t.sub(timez.now()) / timez.SECOND;
    if d < 0 {
        return 0;
    }
    return d;
}

fn session_cache_key(h: bytes) -> str {
    return "session:" + encoding.hex_encode(h);
}

fn lower_trim(s: str) -> str {
    return strings.to_lower(strings.trim(s));
}

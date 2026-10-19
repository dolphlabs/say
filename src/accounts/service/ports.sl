import "timez";
import "../domain" as domain;
import "../../ledger/domain" as ledger;

pub enum Fault {
    Unavailable,
    UsernameTaken,
    EmailTaken,
    IdentityTaken,
    CoolingDown,
    HourlyCap,
    NotFound,
    LastSignInMethod
}

pub gc struct StoreFail {
    fault: Fault,
    detail: str,
    retry_after: int
}

pub gc struct NewSession {
    token_hash: bytes,
    ttl_seconds: int,
    ip: str,
    user_agent: str
}

pub gc struct NewSignup {
    account_id: str,
    username: str,
    email: str,
    password_hash: str,
    password_algo: str,
    password_params: str,
    code_hmac: bytes,
    otp_ttl_seconds: int,
    signup_token_hash: bytes,
    signup_ttl_seconds: int,
    outbox_payload: str
}

pub gc struct NewCode {
    account_id: str,
    email: str,
    purpose: str,
    code_hmac: bytes,
    otp_ttl_seconds: int,
    outbox_payload: str,
    cooldown_seconds: int,
    max_per_hour: int
}

pub gc struct CodeSent {
    outbox_id: str,
    resend_available_at: timez.Time
}

pub gc struct Pending {
    account_id: str,
    username: str,
    email: str,
    status: str
}

pub gc struct LoginRow {
    account_id: str,
    username: str,
    email: str,
    status: str,
    password_hash: opt[str]
}

pub enum CodeCheck {
    Matched,
    Wrong,
    Expired,
    Locked,
    Missing
}

pub gc struct CodeUse {
    account_id: str,
    purpose: str,
    code_hmac: bytes
}

pub gc struct VerifyEmail {
    code: CodeUse,
    grant_amount: int,
    session: NewSession
}

pub gc struct Verified {
    check: CodeCheck,
    attempts_left: int,
    account: opt[domain.Account],
    grant: opt[ledger.Grant]
}

pub gc struct ResetPassword {
    code: CodeUse,
    password_hash: str,
    password_algo: str,
    password_params: str
}

pub gc struct ResetDone {
    check: CodeCheck,
    attempts_left: int,
    revoked: [bytes]
}

pub gc struct SessionRow {
    session_id: str,
    account_id: str,
    status: str,
    expires_at: timez.Time
}

pub gc struct GoogleSignup {
    account_id: str,
    username: str,
    email: str,
    subject: str,
    grant_amount: int,
    session: NewSession
}

pub gc struct Created {
    account: domain.Account,
    grant: opt[ledger.Grant]
}

pub gc struct AuditEvent {
    actor_id: str,
    action: str,
    ip: str,
    user_agent: str,
    detail_json: str
}

pub gc struct OutboxItem {
    id: str,
    kind: str,
    payload: str,
    attempts: int
}

pub gc struct Mail {
    to: str,
    username: str,
    purpose: str,
    code: str
}

pub gc struct JwksDoc {
    body: str,
    max_age_seconds: int
}

// Everything auth needs from outside: Postgres (authoritative), Redis
// (holds, caches, counters; every call may fail and the service copes),
// Google, and nothing else. `C` is the adapter's own state.
pub gc struct AuthStore[C] {
    context: C,

    usernames_taken: fn(C, [str]) -> result[[str], StoreFail],
    create_signup: fn(C, NewSignup) -> result[CodeSent, StoreFail],
    replace_code: fn(C, NewCode) -> result[CodeSent, StoreFail],
    signup_account: fn(C, bytes) -> result[opt[Pending], StoreFail],
    issue_signup_token: fn(C, str, bytes, int) -> result[bool, StoreFail],
    verify_email: fn(C, VerifyEmail) -> result[Verified, StoreFail],
    reset_password: fn(C, ResetPassword) -> result[ResetDone, StoreFail],

    find_login: fn(C, str) -> result[opt[LoginRow], StoreFail],
    set_password_hash: fn(C, str, str, str, str) -> result[bool, StoreFail],
    create_session: fn(C, str, NewSession) -> result[bool, StoreFail],
    session_lookup: fn(C, bytes) -> result[opt[SessionRow], StoreFail],
    revoke_session: fn(C, bytes) -> result[bool, StoreFail],
    revoke_others: fn(C, str, bytes) -> result[[bytes], StoreFail],
    touch_session: fn(C, bytes) -> result[bool, StoreFail],

    account: fn(C, str) -> result[opt[domain.Account], StoreFail],
    password_hash_of: fn(C, str) -> result[opt[str], StoreFail],
    change_password: fn(C, str, str, str, str, bytes) -> result[[bytes], StoreFail],
    unlink_google: fn(C, str) -> result[bool, StoreFail],
    delete_account: fn(C, str) -> result[[bytes], StoreFail],

    identity_owner: fn(C, str) -> result[opt[str], StoreFail],
    email_owner: fn(C, str) -> result[opt[str], StoreFail],
    create_google_account: fn(C, GoogleSignup) -> result[Created, StoreFail],
    link_google: fn(C, str, str, str) -> result[bool, StoreFail],

    insert_audit: fn(C, [AuditEvent]) -> result[int, str],
    claim_outbox: fn(C, str, int, int) -> result[[OutboxItem], str],
    outbox_sent: fn(C, str) -> result[bool, str],
    outbox_retry: fn(C, str, str, int) -> result[bool, str],
    sweep_expired: fn(C) -> result[int, str],

    eph_put_nx: fn(C, str, str, int) -> result[bool, str],
    eph_put: fn(C, str, str, int) -> result[bool, str],
    eph_get: fn(C, str) -> result[opt[str], str],
    eph_take: fn(C, str) -> result[opt[str], str],
    eph_drop: fn(C, [str]) -> result[int, str],
    eph_hit: fn(C, str, int) -> result[int, str],

    google_exchange: fn(C, str, str, str) -> result[str, str],
    google_jwks: fn(C) -> result[JwksDoc, str]
}

pub gc struct Mailer[M] {
    context: M,
    send: fn(M, Mail) -> result[bool, str]
}

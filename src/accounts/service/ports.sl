import "../domain" as domain;

pub gc struct AuditMeta {
    ip_address: opt[str],
    user_agent: opt[str],
    fingerprint: opt[str],
    detail_json: str
}

pub gc struct AccountStore[C] {
    context: C,
    insert: fn(C, domain.Account) -> result[bool, str],
    find: fn(C, str, str) -> result[opt[domain.Account], str],
    find_by_username: fn(C, str, str) -> result[opt[domain.Account], str],
    find_by_email: fn(C, str, str) -> result[opt[domain.Account], str],
    find_by_phone: fn(C, str, str) -> result[opt[domain.Account], str],
    list: fn(C, str, int, int) -> result[[domain.Account], str],
    record_signup_audit: fn(C, str, str, AuditMeta) -> result[bool, str],
    verify_email: fn(C, str, str) -> result[bool, str]
}

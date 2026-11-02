import "../domain" as domain;

pub gc struct AuditStore[C] {
    context: C,
    query_events: fn(C, domain.AuditFilter) -> result[domain.AuditPage, str],
    create_export: fn(C, str, str, str) -> result[str, str],
    load_export: fn(C, str) -> result[opt[str], str]
}

pub gc struct AuditEvent {
    id: str,
    actor_id: str,
    actor_kind: str,
    role_at_time: str,
    area: str,
    action: str,
    target_type: str,
    target_id: str,
    ip_address: str,
    detail: str,
    links: str,
    created_at_ms: int
}

pub gc struct AuditFilter {
    area: str,
    actor: str,
    target_type: str,
    target_id: str,
    from_ms: int,
    to_ms: int,
    cursor: str,
    limit: int
}

pub gc struct AuditPage {
    items: [AuditEvent],
    next_cursor: str
}

pub gc struct ExportJob {
    id: str,
    requested_by: str,
    status: str,
    download_url: str,
    created_at: int
}

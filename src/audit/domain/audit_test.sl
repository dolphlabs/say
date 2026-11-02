fn test_audit_event_structure() {
    let ev = AuditEvent {
        id: "evt-1",
        actor_id: "acc-1",
        actor_kind: "staff",
        role_at_time: "super_admin",
        area: "Money",
        action: "BOT_TOPUP_APPROVED",
        target_type: "bot",
        target_id: "bot-1",
        ip_address: "127.0.0.1",
        detail: "{}",
        links: "{}",
        created_at_ms: 1700000000000
    };
    assert(ev.area == "Money");
    assert(ev.actor_kind == "staff");
}

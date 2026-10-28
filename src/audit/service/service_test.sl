import "../domain" as domain;

gc struct FakeStoreContext {
    dummy: int
}

fn fake_query_events(ctx: FakeStoreContext, f: domain.AuditFilter) -> result[domain.AuditPage, str] {
    let ev = domain.AuditEvent {
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
        created_at_ms: 1000
    };
    return ok(domain.AuditPage { items: [ev], next_cursor: "" });
}

fn fake_create_export(ctx: FakeStoreContext, req_id: str, f: str, csv: str) -> result[str, str] {
    return ok("exp-1");
}

fn fake_load_export(ctx: FakeStoreContext, id: str) -> result[opt[str], str] {
    return ok(some("csv,data\n1,2"));
}

fn test_audit_service_lifecycle() {
    let ctx = FakeStoreContext { dummy: 0 };
    let st = AuditStore[FakeStoreContext] {
        context: ctx,
        query_events: fake_query_events,
        create_export: fake_create_export,
        load_export: fake_load_export
    };
    let svc = new_service(st);

    let q_res = get_audit_log(svc, domain.AuditFilter {
        area: "Money",
        actor: "",
        target_type: "",
        target_id: "",
        from_ms: 0,
        to_ms: 0,
        cursor: "",
        limit: 10
    });
    guard let page = q_res else let e = err_of(q_res) { panic(e); }
    assert(len(page.items) == 1);
    assert(page.items[0].area == "Money");

    let exp_res = export_audit_csv(svc, "acc-1", domain.AuditFilter {
        area: "",
        actor: "",
        target_type: "",
        target_id: "",
        from_ms: 0,
        to_ms: 0,
        cursor: "",
        limit: 10
    }, "https://say.it");
    guard let exp = exp_res else let e = err_of(exp_res) { panic(e); }
    assert(exp.id == "exp-1");

    let load_res = download_csv(svc, "exp-1");
    guard let opt_data = load_res else let e = err_of(load_res) { panic(e); }
    guard let data = opt_data else { panic("expected csv data"); }
    assert(len(data) > 0);
}

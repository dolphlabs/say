import "builder";
import "../domain" as domain;

pub gc struct AuditService[C] {
    store: AuditStore[C]
}

pub fn new_service[C](s: AuditStore[C]) -> AuditService[C] {
    return AuditService[C] { store: s };
}

pub fn get_audit_log[C](svc: AuditService[C], filter: domain.AuditFilter) -> result[domain.AuditPage, str] {
    let q_fn = svc.store.query_events;
    return q_fn(svc.store.context, filter);
}

pub fn export_audit_csv[C](svc: AuditService[C], requester_id: str, filter: domain.AuditFilter, base_url: str) -> result[domain.ExportJob, str] {
    let page_filter = filter;
    page_filter.limit = 1000;
    let q_fn = svc.store.query_events;
    let events_res = q_fn(svc.store.context, page_filter);
    guard let page = events_res else let e = err_of(events_res) {
        return err(e);
    }

    let csv = builder.new_str();
    csv.write("id,created_at_ms,actor_id,actor_kind,role_at_time,area,action,target_type,target_id,ip_address,links,detail\n");
    for ev in page.items {
        csv.write(ev.id);
        csv.write(",");
        csv.write(to_str(ev.created_at_ms));
        csv.write(",");
        csv.write(ev.actor_id);
        csv.write(",");
        csv.write(ev.actor_kind);
        csv.write(",");
        csv.write(ev.role_at_time);
        csv.write(",");
        csv.write(ev.area);
        csv.write(",");
        csv.write(ev.action);
        csv.write(",");
        csv.write(ev.target_type);
        csv.write(",");
        csv.write(ev.target_id);
        csv.write(",");
        csv.write(ev.ip_address);
        csv.write(",\"{}\",\"{}\"\n");
    }

    let csv_content = csv.finish();
    let create_fn = svc.store.create_export;
    let export_id_res = create_fn(svc.store.context, requester_id, "{}", csv_content);
    guard let exp_id = export_id_res else let e = err_of(export_id_res) {
        return err(e);
    }

    let download_url = base_url + "/v1/admin/audit/export/" + exp_id;
    return ok(domain.ExportJob {
        id: exp_id,
        requested_by: requester_id,
        status: "READY",
        download_url: download_url,
        created_at: 0
    });
}

pub fn download_csv[C](svc: AuditService[C], export_id: str) -> result[opt[str], str] {
    let load_fn = svc.store.load_export;
    return load_fn(svc.store.context, export_id);
}

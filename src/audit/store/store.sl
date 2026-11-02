import "pg";
import "time";
import "zokor";
import "../domain" as domain;
import "../service" as ports;

pub gc struct PostgresAuditStore {
    conn: pg.Pool
}

pub fn new_store(pool: pg.Pool) -> PostgresAuditStore {
    return PostgresAuditStore { conn: pool };
}

gc struct AuditEventSqlRow {
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

gc struct AuditIdRow {
    id: str
}

gc struct CsvContentRow {
    csv_content: str
}

fn au_dl() -> until {
    return until_of(time.mono() + 5000000000);
}

pub fn query_events(s: PostgresAuditStore, f: domain.AuditFilter) -> result[domain.AuditPage, str] {
    let limit_n = f.limit;
    if limit_n <= 0 || limit_n > 100 { limit_n = 50; }

    let q = "select id::text as id, coalesce(actor_id::text, '') as actor_id, " +
        "coalesce(actor_kind, 'player') as actor_kind, " +
        "coalesce(role_at_time, '') as role_at_time, " +
        "coalesce(area, 'Access') as area, " +
        "action, target_type, coalesce(target_id, '') as target_id, " +
        "coalesce(host(ip_address), '') as ip_address, " +
        "coalesce(detail::text, '{}') as detail, " +
        "coalesce(links::text, '{}') as links, " +
        "(extract(epoch from created_at)*1000)::bigint as created_at_ms " +
        "from audit_events where " +
        "($1 = '' or area = $1) and " +
        "($2 = '' or actor_id = $2::uuid) and " +
        "($3 = '' or target_type = $3) and " +
        "($4 = '' or target_id = $4) and " +
        "($5 = 0 or created_at >= to_timestamp($5 / 1000.0)) and " +
        "($6 = 0 or created_at <= to_timestamp($6 / 1000.0)) " +
        "order by created_at desc, id desc limit $7";

    let r: result[[AuditEventSqlRow], str] = zokor.query_all(s.conn, q, [
        pg.arg_text(f.area),
        pg.arg_text(f.actor),
        pg.arg_text(f.target_type),
        pg.arg_text(f.target_id),
        pg.arg_int(f.from_ms),
        pg.arg_int(f.to_ms),
        pg.arg_int(limit_n + 1)
    ], au_dl());
    guard let rows = r else let e = err_of(r) { return err(e); }

    let items: [domain.AuditEvent] = [];
    let next_cursor = "";
    let count = len(rows);
    let slice_count = count;
    if count > limit_n { slice_count = limit_n; }

    for i in 0..slice_count {
        let row = rows[i];
        push(items, domain.AuditEvent {
            id: row.id,
            actor_id: row.actor_id,
            actor_kind: row.actor_kind,
            role_at_time: row.role_at_time,
            area: row.area,
            action: row.action,
            target_type: row.target_type,
            target_id: row.target_id,
            ip_address: row.ip_address,
            detail: row.detail,
            links: row.links,
            created_at_ms: row.created_at_ms
        });
    }

    if count > limit_n {
        let last = items[limit_n - 1];
        next_cursor = last.id;
    }

    return ok(domain.AuditPage {
        items: items,
        next_cursor: next_cursor
    });
}

pub fn create_export(s: PostgresAuditStore, requester_id: str, filters_json: str, csv_data: str) -> result[str, str] {
    let q = "insert into audit_exports(requested_by, filters, status, csv_content, created_at, expires_at) " +
        "values($1::uuid, $2::jsonb, 'READY', $3, now(), now() + interval '2 hours') " +
        "returning id::text as id";
    let r: result[[AuditIdRow], str] = zokor.query_all(s.conn, q, [pg.arg_text(requester_id), pg.arg_text(filters_json), pg.arg_text(csv_data)], au_dl());
    guard let rows = r else let e = err_of(r) { return err(e); }
    return ok(rows[0].id);
}

pub fn load_export(s: PostgresAuditStore, export_id: str) -> result[opt[str], str] {
    let q = "select csv_content from audit_exports where id = $1::uuid and expires_at > now() and status = 'READY'";
    let r: result[[CsvContentRow], str] = zokor.query_all(s.conn, q, [pg.arg_text(export_id)], au_dl());
    guard let rows = r else let e = err_of(r) { return err(e); }
    if len(rows) == 0 {
        let none_val: opt[str] = none;
        return ok(none_val);
    }
    return ok(some(rows[0].csv_content));
}

pub fn audit_store(s: PostgresAuditStore) -> ports.AuditStore[PostgresAuditStore] {
    return ports.AuditStore[PostgresAuditStore] {
        context: s,
        query_events: query_events,
        create_export: create_export,
        load_export: load_export
    };
}

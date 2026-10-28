import "pg";
import "zokor";
import "../service" as service;

gc struct Id { id: str }

pub fn request(c: pg.Conn, kind: str, subject_type: str, subject_id: str, hash: str,
               requester: str, round: int, slot: int, reason: str, now: int, d: until) -> result[str, str] {
    let r: result[[Id], str] = zokor.conn_query_all(c,
        "with r as (insert into approval_requests(kind,subject_type,subject_id,payload_hash,requested_by,approval_round,slot,reason,created_at,expires_at) " +
        "values($1,$2,$3::uuid,$4,$5::uuid,$6,$7,$8,to_timestamp($9/1000.0),to_timestamp($9/1000.0)+interval '7 days') returning id) " +
        "insert into approval_state(approval_id) select id from r returning approval_id::text as id",
        [pg.arg_text(kind),pg.arg_text(subject_type),pg.arg_text(subject_id),pg.arg_text(hash),pg.arg_text(requester),
         pg.arg_int(round),pg.arg_int(slot),pg.arg_text(reason),pg.arg_int(now)],d);
    guard let rows = r else let e = err_of(r) { return err(e); }
    return ok(rows[0].id);
}

pub fn pending(c: pg.Conn, kind: str, subject_id: str, hash: str, d: until) -> result[opt[service.Request], str] {
    let r: result[[service.Request], str] = zokor.conn_query_all(c,
        "select r.id::text as id,r.kind,r.subject_type,r.subject_id::text as subject_id,r.payload_hash," +
        "r.requested_by::text as requested_by,r.approval_round,r.slot,s.status,s.version," +
        "(extract(epoch from r.expires_at)*1000)::bigint as expires_at " +
        "from approval_requests r join approval_state s on s.approval_id=r.id " +
        "where r.kind=$1 and r.subject_id=$2::uuid and r.payload_hash=$3 and s.status='pending' order by r.slot limit 1 for update of s",
        [pg.arg_text(kind),pg.arg_text(subject_id),pg.arg_text(hash)],d);
    guard let rows = r else let e = err_of(r) { return err(e); }
    let missing: opt[service.Request] = none;
    if len(rows) == 0 { return ok(missing); }
    return ok(some(rows[0]));
}

pub fn decide(c: pg.Conn, r: service.Request, actor: str, decision: str, note: str, now: int, d: until) -> result[bool, str] {
    if actor == r.requested_by { return err("SELF_APPROVAL_FORBIDDEN"); }
    if now >= r.expires_at { return err("STALE_APPROVAL"); }
    let written: result[[Id], str] = zokor.conn_query_all(c,
        "with d as (insert into approval_decisions(approval_id,decided_by,decision,note,decided_at) " +
        "values($1::uuid,$2::uuid,$3,$4,to_timestamp($5/1000.0)) returning id) " +
        "update approval_state s set status=$3,decision_id=d.id,version=version+1 from d " +
        "where s.approval_id=$1::uuid and s.status='pending' and s.version=$6 returning s.approval_id::text as id",
        [pg.arg_text(r.id),pg.arg_text(actor),pg.arg_text(decision),pg.arg_text(note),pg.arg_int(now),pg.arg_int(r.version)],d);
    guard let rows = written else let e = err_of(written) { return err(e); }
    if len(rows) != 1 { return err("STALE_APPROVAL"); }
    let payload = zokor.jobj().set_str("approval_id",r.id).set_str("kind",r.kind).set_str("subject_id",r.subject_id)
        .set_str("payload_hash",r.payload_hash).set_str("decision",decision);
    let emitted = pg.query(c,
        "insert into outbox_events(type,payload,created_at) values('approval.decided',$1::jsonb,to_timestamp($2/1000.0))",
        [pg.arg_text(payload.render()),pg.arg_int(now)],d);
    guard let _n = emitted else let e = err_of(emitted) { return err(e); }
    return ok(true);
}

pub fn stale(c: pg.Conn, kind: str, subject_id: str, reason: str, now: int, d: until) -> result[bool,str] {
    let r = pg.query(c,
        "with changed as (update approval_state s set status='stale',version=version+1 from approval_requests r " +
        "where r.id=s.approval_id and r.kind=$1 and r.subject_id=$2::uuid and s.status='pending' returning s.approval_id) " +
        "insert into approval_transitions(approval_id,from_status,to_status,reason,at) " +
        "select approval_id,'pending','stale',$3,to_timestamp($4/1000.0) from changed",
        [pg.arg_text(kind),pg.arg_text(subject_id),pg.arg_text(reason),pg.arg_int(now)],d);
    guard let _n = r else let e = err_of(r) { return err(e); }
    return ok(true);
}

pub fn applied(c: pg.Conn, approval_id: str, subject_id: str, now: int, d: until) -> result[bool,str] {
    let r = pg.query(c,
        "insert into approval_applications(approval_id,subject_id,applied_at) values($1::uuid,$2::uuid,to_timestamp($3/1000.0)) on conflict do nothing",
        [pg.arg_text(approval_id),pg.arg_text(subject_id),pg.arg_int(now)],d);
    guard let _n = r else let e = err_of(r) { return err(e); }
    return ok(true);
}

pub fn load_by_id(c: pg.Conn, approval_id: str, d: until) -> result[opt[service.Request], str] {
    let r = zokor.conn_query_all(c,
        "select r.id::text as id, r.kind, r.subject_type, r.subject_id::text as subject_id, r.payload_hash, " +
        "r.requested_by::text as requested_by, r.approval_round, r.slot, s.status, s.version, " +
        "(extract(epoch from r.expires_at)*1000)::bigint as expires_at " +
        "from approval_requests r join approval_state s on s.approval_id = r.id " +
        "where r.id = $1::uuid",
        [pg.arg_text(approval_id)], d);
    guard let rows = r else let e = err_of(r) { return err(e); }
    if len(rows) == 0 {
        let none_val: opt[service.Request] = none;
        return ok(none_val);
    }
    return ok(some(rows[0]));
}

pub fn list_inbox(c: pg.Conn, status_filter: str, kind_filter: str, d: until) -> result[[service.ApprovalInboxItem], str] {
    let q = "select r.id::text, r.kind, r.subject_type, r.subject_id::text, r.payload_hash, " +
        "r.requested_by::text, a.username as requester_username, coalesce(ar.role, 'staff') as requester_role, " +
        "(extract(epoch from r.created_at)*1000)::bigint as requested_at, " +
        "s.status, r.reason, " +
        "coalesce(r.reason, r.kind) as title " +
        "from approval_requests r " +
        "join approval_state s on s.approval_id = r.id " +
        "join accounts a on a.id = r.requested_by " +
        "left join lateral (select role from account_roles where account_id = r.requested_by limit 1) ar on true " +
        "where ($1 = '' or s.status = $1 or ($1 = 'decided' and s.status in ('approved', 'rejected'))) " +
        "  and ($2 = '' or r.kind = $2) " +
        "order by r.created_at desc limit 50";

    let r = zokor.conn_query_all(c, q, [pg.arg_text(status_filter), pg.arg_text(kind_filter)], d);
    guard let rows = r else let e = err_of(r) { return err(e); }

    let out: [service.ApprovalInboxItem] = [];
    for row in rows {
        let id = row.get_str("id");
        let kind = row.get_str("kind");
        let subject_id = row.get_str("subject_id");
        let title = row.get_str("title");
        let reason = row.get_str("reason");
        let req_user = row.get_str("requester_username");
        let req_role = row.get_str("requester_role");
        let req_id = row.get_str("requested_by");
        let req_at = row.get_int("requested_at");
        let p_hash = row.get_str("payload_hash");
        let status = row.get_str("status");

        let sub_link = "/v1/admin/approvals/" + id;
        if kind == "market_open" {
            sub_link = "/v1/markets/" + subject_id;
        } else if kind == "liquidity" || kind == "bot_topup" {
            sub_link = "/v1/admin/bots";
        }

        push(out, service.ApprovalInboxItem {
            id: id,
            kind: kind,
            title: title,
            detail: reason,
            requested_by: service.RequesterInfo { username: req_user, role: req_role },
            requester_account_id: req_id,
            requested_at: req_at,
            can_decide: true,
            cannot_decide_reason: "",
            subject_link: sub_link,
            payload_hash: p_hash,
            status: status
        });
    }
    return ok(out);
}

fn st_request(pool: pg.Pool, kind: str, subject_type: str, subject_id: str, hash: str, requester: str, round: int, slot: int, reason: str, now: int) -> result[str, str] {
    let conn_r = pg.acquire(pool, until_max());
    guard let conn = conn_r else let e = err_of(conn_r) { return err(e); }
    let r = request(conn, kind, subject_type, subject_id, hash, requester, round, slot, reason, now, until_max());
    pg.release(pool, conn);
    return r;
}

fn st_load_by_id(pool: pg.Pool, id: str) -> result[opt[service.Request], str] {
    let conn_r = pg.acquire(pool, until_max());
    guard let conn = conn_r else let e = err_of(conn_r) { return err(e); }
    let r = load_by_id(conn, id, until_max());
    pg.release(pool, conn);
    return r;
}

fn st_list_inbox(pool: pg.Pool, status_filter: str, kind_filter: str) -> result[[service.ApprovalInboxItem], str] {
    let conn_r = pg.acquire(pool, until_max());
    guard let conn = conn_r else let e = err_of(conn_r) { return err(e); }
    let r = list_inbox(conn, status_filter, kind_filter, until_max());
    pg.release(pool, conn);
    return r;
}

fn st_decide(pool: pg.Pool, req: service.Request, actor: str, decision: str, note: str, now: int) -> result[bool, str] {
    let conn_r = pg.acquire(pool, until_max());
    guard let conn = conn_r else let e = err_of(conn_r) { return err(e); }
    let r = decide(conn, req, actor, decision, note, now, until_max());
    pg.release(pool, conn);
    return r;
}

pub fn approval_store(pool: pg.Pool) -> service.ApprovalStore[pg.Pool] {
    return service.ApprovalStore[pg.Pool] {
        context: pool,
        request: st_request,
        load_by_id: st_load_by_id,
        list_inbox: st_list_inbox,
        decide: st_decide
    };
}

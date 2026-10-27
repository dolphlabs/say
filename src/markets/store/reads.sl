import "pg";
import "strings";
import "zokor";
import "../domain" as domain;
import "../service" as service;
import "../../ledger/store" as ledger_store;

fn failure_text(f: service.Failed) -> str {
    let items=zokor.jarr();
    for p in f.problems { items.add(zokor.jobj().set_str("code",p.code).set_str("field",p.field).set_str("message",p.message)); }
    return zokor.jobj().set_bool("market_failure",true).set_str("code",f.code).set_str("detail",f.detail).set("problems",items).render();
}

fn parse_failure(text: str) -> service.Failed {
    let r=zokor.parse(text);
    if let j=r {
        if j.get("market_failure").bool_or(false) {
            let issues: [domain.Problem]=[];
            for p in j.get("problems").items_of() { push(issues,domain.Problem { code:p.get("code").str_or("BAD_REQUEST"),
                field:p.get("field").str_or("request"),message:p.get("message").str_or("") }); }
            return service.Failed { code:j.get("code").str_or("UNAVAILABLE"),detail:j.get("detail").str_or(""),problems:issues };
        }
    }
    return service.failure("UNAVAILABLE",text);
}

gc struct FindArg { store: Store, selector: str, actor_id: str }

fn find_tx(c: pg.Conn,a: FindArg) -> result[opt[domain.Market],str] {
    let r=read_market(c,a.selector,false,deadline(a.store));
    guard let found=r else let e=err_of(r) { return err(e); }
    let missing: opt[domain.Market]=none;
    guard let m=found else { return ok(missing); }
    if len(a.actor_id)==0 {
        if !domain.public_status(m.status) { return ok(missing); }
    } else {
        let ar=actor(c,a.actor_id,deadline(a.store));
        guard let caller=ar else let e=err_of(ar) { return err(e); }
        if domain.authorize(caller,"read",m)!="" { return ok(missing); }
    }
    return ok(some(m));
}

fn find(s: Store, selector: str, actor_id: str) -> result[opt[domain.Market],service.Failed] {
    let r=zokor.transaction(s.pool,FindArg { store:s,selector:selector,actor_id:actor_id },find_tx,deadline(s));
    guard let found=r else let e=err_of(r) { return err(parse_failure(e)); }
    return ok(found);
}

gc struct SnapshotArg { store: Store, now: int }

fn snapshot_tx(c: pg.Conn,a: SnapshotArg) -> result[service.Snapshot,str] {
    let d=deadline(a.store);
    let no_args: [pg.Arg]=[];
    let iso=exec(c,"set transaction isolation level repeatable read read only",no_args,d);
    guard let _i=iso else let e=err_of(iso) { return err(e); }
    let mr: result[[domain.Market],str]=zokor.conn_query_all(c,"select * from market_registry_rows order by created_at desc,id desc",no_args,d);
    guard let markets=mr else let e=err_of(mr) { return err(e); }
    let cr: result[[service.Category],str]=zokor.conn_query_all(c,"select id::text as id,name,icon,sort_order from categories order by sort_order,id",no_args,d);
    guard let categories=cr else let e=err_of(cr) { return err(e); }
    let sr: result[[service.Source],str]=zokor.conn_query_all(c,"select id::text as id,name,url_pattern,kind,approved from resolution_sources order by name,id",no_args,d);
    guard let sources=sr else let e=err_of(sr) { return err(e); }
    let tr: result[[service.Stats],str]=zokor.conn_query_all(c,
        "select market_id::text as market_id,last_price,yes_bid,yes_ask,no_bid,no_ask,volume_units,volume_24h_units,players,change_24h::text as change_24h from market_stats",no_args,d);
    guard let stats=tr else let e=err_of(tr) { return err(e); }
    let yr: result[[service.Season],str]=zokor.conn_query_all(c,
        "select id::text as id,ordinal,status,(extract(epoch from starts_at)*1000)::bigint as starts_at," +
        "(extract(epoch from ends_at)*1000)::bigint as ends_at from seasons order by ordinal",no_args,d);
    guard let seasons=yr else let e=err_of(yr) { return err(e); }
    return ok(service.new_snapshot(markets,categories,sources,stats,seasons,a.now));
}

fn read_snapshot(s: Store, now: int) -> result[service.Snapshot,str] {
    return zokor.transaction(s.pool,SnapshotArg { store:s,now:now },snapshot_tx,deadline(s));
}

fn due(s: Store, now: int) -> result[[domain.Market],str] {
    return zokor.query_all(s.pool,
        "select r.* from markets m join market_registry_rows r on r.id=m.id::text left join seasons s on s.id=m.season_id where " +
        "(m.status in ('OPEN','SUSPENDED') and (m.close_at<=to_timestamp($1::bigint/1000.0) or s.status<>'ACTIVE' or s.ends_at<=to_timestamp($1::bigint/1000.0))) " +
        "or m.status in ('CLOSED','APPROVED') or (m.status='FUNDING' and m.open_at<=to_timestamp($1::bigint/1000.0) and m.close_at>to_timestamp($1::bigint/1000.0)) " +
        "order by case when m.status in ('OPEN','SUSPENDED') then 0 when m.status='CLOSED' then 1 else 2 end,m.close_at,m.id limit 1000",[pg.arg_int(now)],deadline(s));
}

gc struct HistoryRow { document: str }

fn history(s: Store,id: str,actor_id: str) -> result[str,service.Failed] {
    let r=find(s,id,actor_id);
    guard let found=r else let f=err_of(r) { return err(f); }
    guard let m=found else { return err(service.failure("NOT_FOUND","")); }
    let q: result[[HistoryRow],str]=zokor.query_all(s.pool,
        "select jsonb_build_object('terms',coalesce((select jsonb_agg(to_jsonb(t) order by terms_version) from market_terms_versions t where t.market_id=$1::uuid),'[]'::jsonb)," +
        "'approvals',coalesce((select jsonb_agg(to_jsonb(a) order by created_at) from approvals a where a.subject_id=$1::uuid),'[]'::jsonb)," +
        "'audit',coalesce((select jsonb_agg(to_jsonb(x) order by created_at,id) from (select * from audit_events where target_type='market' and target_id=$1 order by created_at desc,id desc limit 200) x),'[]'::jsonb))::text as document",
        [pg.arg_text(m.id)],deadline(s));
    guard let rows=q else let e=err_of(q) { return err(service.failure("UNAVAILABLE",e)); }
    return ok(rows[0].document);
}

gc struct SourceArg { store: Store, actor_id: str, name: str, url: str, kind: str, now: int }

fn source_tx(c: pg.Conn,a: SourceArg) -> result[service.Source,str] {
    let d=deadline(a.store);
    let ar=actor(c,a.actor_id,d);
    guard let caller=ar else let e=err_of(ar) { return err(e); }
    if !domain.reviewer(caller) { return err(failure_text(service.failure("FORBIDDEN_ROLE",""))); }
    let rr: result[[service.Source],str]=zokor.conn_query_all(c,
        "insert into resolution_sources(name,url_pattern,kind,created_by,created_at) values($1,$2,$3,$4::uuid,to_timestamp($5::bigint/1000.0)) " +
        "returning id::text as id,name,url_pattern,kind,approved",
        [pg.arg_text(a.name),pg.arg_text(a.url),pg.arg_text(a.kind),pg.arg_text(a.actor_id),pg.arg_int(a.now)],d);
    guard let rows=rr else let e=err_of(rr) { return err(e); }
    let r=exec(c,
        "with a as (insert into audit_events(actor_id,action,target_type,target_id,detail,created_at) " +
        "values($1::uuid,'resolution_source.created','resolution_source',$2,'{}'::jsonb,to_timestamp($3::bigint/1000.0))) " +
        "insert into outbox_events(type,payload,created_at) values('resolution_source.created',jsonb_build_object('source_id',$2::text),to_timestamp($3::bigint/1000.0))",
        [pg.arg_text(a.actor_id),pg.arg_text(rows[0].id),pg.arg_int(a.now)],d);
    guard let _r=r else let e=err_of(r) { return err(e); }
    return ok(rows[0]);
}

fn source_create(s: Store,actor_id: str,name: str,url: str,kind: str,now: int) -> result[service.Source,service.Failed] {
    if len(name)<3 || len(name)>140 || !strings.has_prefix(url,"https://") || len(url)>2048 || (kind!="html" && kind!="json") {
        return err(service.failure("BAD_REQUEST","Invalid resolution source."));
    }
    let r=zokor.transaction(s.pool,SourceArg { store:s,actor_id:actor_id,name:name,url:url,kind:kind,now:now },source_tx,deadline(s));
    guard let source=r else let e=err_of(r) { return err(parse_failure(e)); }
    return ok(source);
}

fn lease_try(s: Store,key: int) -> result[opt[int],str] { return ledger_store.worker_lease_try(s.coordinator,key); }
fn lease_release(s: Store,id: int) { ledger_store.worker_lease_release(s.coordinator,id); }

gc struct ValidateArg { store: Store, market: domain.Market, full: bool, now: int }

fn validate_tx(c: pg.Conn,a: ValidateArg) -> result[[domain.Problem],str] {
    let r=facts(c,a.market,deadline(a.store));
    guard let f=r else let e=err_of(r) { return err(e); }
    return ok(market_problems(a.store,a.market,a.full,f,a.now));
}

fn validate(s: Store,m: domain.Market,full: bool,now: int) -> result[[domain.Problem],service.Failed] {
    let r=zokor.transaction(s.pool,ValidateArg { store:s,market:m,full:full,now:now },validate_tx,deadline(s));
    guard let issues=r else let e=err_of(r) { return err(service.failure("UNAVAILABLE",e)); }
    return ok(issues);
}

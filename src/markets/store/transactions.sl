import "pg";
import "timez";
import "zokor";
import "../domain" as domain;
import "../service" as service;
import "../../approvals/store" as approvals;

gc struct Role { role: str }
gc struct Active { active: bool }
gc struct SeasonFacts { status: str, starts: int, ends: int, ordinal: int, next_ordinal: int }
gc struct SourceFacts { approved: bool, snapshot: str }
gc struct Found { present: bool }
gc struct Facts { facts: domain.Facts, source: str, ordinal: int, next_ordinal: int }
gc struct Mutation { store: Store, command: service.Command }

fn exec(c: pg.Conn, sql: str, args: [pg.Arg], d: until) -> result[bool,str] {
    let r = pg.query(c,sql,args,d);
    guard let _n = r else let e = err_of(r) { return err(e); }
    return ok(true);
}

fn actor(c: pg.Conn, id: str, d: until) -> result[domain.Actor,str] {
    let r: result[[Active],str] = zokor.conn_query_all(c,
        "select status='ACTIVE' and kind='USER' and deleted_at is null as active from accounts where id=$1::uuid for share",
        [pg.arg_text(id)],d);
    guard let rows = r else let e = err_of(r) { return err(e); }
    if len(rows) == 0 || !rows[0].active { return err("FORBIDDEN_ROLE"); }
    let rr: result[[Role],str] = zokor.conn_query_all(c,
        "select role from account_roles where account_id=$1::uuid order by role",[pg.arg_text(id)],d);
    guard let roles = rr else let e = err_of(rr) { return err(e); }
    let values: [str] = [];
    for r in roles { push(values,r.role); }
    return ok(domain.Actor { id: id, roles: values });
}

fn read_market(c: pg.Conn, id: str, lock: bool, d: until) -> result[opt[domain.Market],str] {
    let q = "select * from market_registry_rows where id=$1 or slug=$1";
    if lock { q = "select * from market_registry_rows where id=$1 or slug=$1 for update"; }
    let r: result[[domain.Market],str] = zokor.conn_query_all(c,q,[pg.arg_text(id)],d);
    guard let rows = r else let e = err_of(r) { return err(e); }
    let missing: opt[domain.Market] = none;
    if len(rows) == 0 { return ok(missing); }
    return ok(some(rows[0]));
}

fn facts(c: pg.Conn, m: domain.Market, d: until) -> result[Facts,str] {
    let status = "";
    let start = 0;
    let end = 0;
    let ordinal=0;
    let next_ordinal=0;
    if len(m.season_id) > 0 {
        let sr: result[[SeasonFacts],str] = zokor.conn_query_all(c,
            "select s.status,(extract(epoch from s.starts_at)*1000)::bigint as starts," +
            "(extract(epoch from s.ends_at)*1000)::bigint as ends,s.ordinal," +
            "coalesce((select min(n.ordinal) from seasons n where n.ordinal>s.ordinal and n.status in ('SCHEDULED','ACTIVE')),0) as next_ordinal " +
            "from seasons s where s.id=$1::uuid for share of s",
            [pg.arg_text(m.season_id)],d);
        guard let seasons = sr else let e = err_of(sr) { return err(e); }
        if len(seasons) > 0 { status=seasons[0].status; start=seasons[0].starts; end=seasons[0].ends; ordinal=seasons[0].ordinal; next_ordinal=seasons[0].next_ordinal; }
    }
    let approved = false;
    let snapshot = "{}";
    if len(m.resolution_source_id) > 0 {
        let rr: result[[SourceFacts],str] = zokor.conn_query_all(c,
            "select approved,jsonb_build_object('id',id,'name',name,'url_pattern',url_pattern,'kind',kind)::text as snapshot " +
            "from resolution_sources where id=$1::uuid for share",[pg.arg_text(m.resolution_source_id)],d);
        guard let sources = rr else let e = err_of(rr) { return err(e); }
        if len(sources) > 0 { approved=sources[0].approved; snapshot=sources[0].snapshot; }
    }
    let cr: result[[Found],str] = zokor.conn_query_all(c,
        "select exists(select 1 from categories where id=nullif($1,'')::uuid) as present",[pg.arg_text(m.category_id)],d);
    guard let categories = cr else let e = err_of(cr) { return err(e); }
    return ok(Facts { facts: domain.Facts { season_status: status,season_start: start,season_end: end,
        source_approved: approved,category_exists: categories[0].present },source: snapshot,ordinal: ordinal,next_ordinal: next_ordinal });
}

fn season_label(ordinal: int) -> str {
    if ordinal<10 { return "Season 0"+to_str(ordinal); }
    return "Season "+to_str(ordinal);
}

fn market_problems(s: Store,m: domain.Market,full: bool,f: Facts,now: int) -> [domain.Problem] {
    let issues=domain.validate(m,full,f.facts,now);
    for problem in issues {
        if problem.code=="CLOSE_AFTER_SEASON_END" && f.facts.season_end>0 && m.close_at>=f.facts.season_end {
            let ending=timez.unix(f.facts.season_end/1000).in_zone(s.zone).format("%a %d %b, %H:%M %Z");
            let next="another eligible season";
            if f.next_ordinal>0 { next=season_label(f.next_ordinal); }
            problem.message="That's after "+season_label(f.ordinal)+" ends ("+ending+"). Pick an earlier close or move it to "+next+".";
        }
    }
    return issues;
}

fn record(c: pg.Conn, m: domain.Market, cmd: service.Command, previous: str, d: until) -> result[bool,str] {
    let event = zokor.jobj().set_str("market_id",m.id).set_str("season_id",m.season_id)
        .set_str("from",previous).set_str("status",m.status).set_int("version",m.version)
        .set_int("terms_version",m.terms_version).set_str("reason",cmd.reason);
    let suffix = cmd.action;
    if cmd.action == "advance" {
        if m.status == "FUNDING" { suffix="funding"; }
        if m.status == "OPEN" { suffix="opened"; }
        if m.status == "CLOSED" { suffix="closed"; }
        if m.status == "RESOLUTION_PENDING" { suffix="resolution_pending"; }
    } else {
        if cmd.action == "create" { suffix="created"; }
        if cmd.action == "edit" { suffix="updated"; }
        if cmd.action == "submit" { suffix="submitted"; }
        if cmd.action == "approve" { suffix="approved"; }
        if cmd.action == "reject" { suffix="rejected"; }
        if cmd.action == "request-changes" { suffix="changes_requested"; }
        if cmd.action == "suspend" { suffix="suspended"; }
        if cmd.action == "resume" { suffix="resumed"; if m.status=="CLOSED" { suffix="closed"; } }
        if cmd.action == "clarify" { suffix="clarified"; }
    }
    let action = "market." + suffix;
    let ar = exec(c,
        "insert into audit_events(actor_id,action,target_type,target_id,detail,created_at) " +
        "values(nullif($1,'')::uuid,$2,'market',$3,$4::jsonb,to_timestamp($5::bigint/1000.0))",
        [pg.arg_text(cmd.actor_id),pg.arg_text(action),pg.arg_text(m.id),pg.arg_text(event.render()),pg.arg_int(cmd.now)],d);
    guard let _a = ar else let e = err_of(ar) { return err(e); }
    return exec(c,"insert into outbox_events(market_id,type,payload,created_at) values($1::uuid,$2,$3::jsonb,to_timestamp($4::bigint/1000.0))",
        [pg.arg_text(m.id),pg.arg_text(action),pg.arg_text(event.render()),pg.arg_int(cmd.now)],d);
}

fn freeze(c: pg.Conn, m: domain.Market, source: str, reason: str, actor_id: str, now: int, d: until) -> result[bool,str] {
    return exec(c,
        "insert into market_terms_versions(market_id,terms_version,question,rules,source_id,close_at,resolve_by,hash," +
        "source_snapshot,policy_snapshot,canonical_payload,reason,created_by,created_at) " +
        "values($1::uuid,$2,$3,$4::jsonb,$5::uuid,to_timestamp($6::bigint/1000.0),to_timestamp($7::bigint/1000.0),$8," +
        "$9::jsonb,$10::jsonb,$11,$12,$13::uuid,to_timestamp($14::bigint/1000.0))",
        [pg.arg_text(m.id),pg.arg_int(m.terms_version),pg.arg_text(m.question),
         pg.arg_text(zokor.jobj().set_str("yes_if",m.yes_if).set_str("no_if",m.no_if).set_str("edge_cases",m.edge_cases).render()),
         pg.arg_text(m.resolution_source_id),pg.arg_int(m.close_at),pg.arg_int(m.resolve_by),pg.arg_text(m.terms_hash),
         pg.arg_text(source),pg.arg_text(document(m).render()),pg.arg_text(domain.terms_payload(m,source)),
         pg.arg_text(reason),pg.arg_text(actor_id),pg.arg_int(now)],d);
}

fn decision(c: pg.Conn, m: domain.Market, cmd: service.Command, d: until) -> result[bool,str] {
    let pr = approvals.pending(c,"market_open",m.id,m.terms_hash,d);
    guard let found = pr else let e = err_of(pr) { return err(e); }
    guard let request = found else { return err("STALE_APPROVAL"); }
    let outcome = "approved";
    if cmd.action == "reject" { outcome="rejected"; }
    let dr = approvals.decide(c,request,cmd.actor_id,outcome,cmd.reason,cmd.now,d);
    guard let _d = dr else let e = err_of(dr) { return err(e); }
    if cmd.action == "approve" { return approvals.applied(c,request.id,m.id,cmd.now,d); }
    return ok(true);
}

fn mutate_tx(c: pg.Conn, tx: Mutation) -> result[domain.Market,str] {
    let cmd=tx.command;
    let d=deadline(tx.store);
    let m=domain.draft(cmd.id,cmd.actor_id,cmd.now);
    if cmd.action != "create" {
        let first=read_market(c,cmd.id,false,d);
        guard let found=first else let e=err_of(first) { return err(failure_text(service.failure("UNAVAILABLE",e))); }
        guard let before=found else { return err(failure_text(service.failure("NOT_FOUND",""))); }
        if len(before.season_id)>0 {
            let season=exec(c,"select id from seasons where id=$1::uuid for share",[pg.arg_text(before.season_id)],d);
            guard let _s=season else let e=err_of(season) { return err(failure_text(service.failure("UNAVAILABLE",e))); }
        }
        let loaded=read_market(c,cmd.id,true,d);
        guard let got=loaded else let e=err_of(loaded) { return err(failure_text(service.failure("UNAVAILABLE",e))); }
        guard let row=got else { return err(failure_text(service.failure("NOT_FOUND",""))); }
        m=row;
    }
    let previous=m.status;
    if cmd.action != "advance" {
        let ar=actor(c,cmd.actor_id,d);
        guard let caller=ar else let e=err_of(ar) { return err(failure_text(service.failure("FORBIDDEN_ROLE",e))); }
        let denied=domain.authorize(caller,cmd.action,m);
        if len(denied)>0 { return err(failure_text(service.failure(denied,""))); }
        if cmd.action != "create" {
            if m.version != cmd.version { return err(failure_text(service.failure("STALE_VERSION",""))); }
            let tr=domain.transition(caller,cmd.action,m,cmd.now);
            guard let target=tr else let e=err_of(tr) { return err(failure_text(service.failure(e,""))); }
            m.status=target;
        }
    } else {
        if m.version != cmd.version { return err(failure_text(service.failure("STALE_VERSION",""))); }
    }
    if cmd.action == "create" || cmd.action == "edit" || cmd.action == "clarify" {
        m=domain.patched(m,cmd.patch);
        if cmd.action == "create" || cmd.action == "edit" { m.slug=domain.slug(m.question,m.id); }
    }
    if cmd.action == "submit" && m.open_at==0 {
        m.open_at=cmd.now;
    }
    let fr=facts(c,m,d);
    guard let f=fr else let e=err_of(fr) { return err(failure_text(service.failure("UNAVAILABLE",e))); }
    if cmd.action=="submit" && m.open_at<f.facts.season_start { m.open_at=f.facts.season_start; }
    if cmd.action=="create" || cmd.action=="edit" || cmd.action=="submit" || cmd.action=="approve" || cmd.action=="clarify" {
        let check=domain.copy(m);
        if cmd.action=="clarify" { check.close_at=cmd.now+1; check.open_at=cmd.now; check.resolve_by=check.close_at+3600000; }
        let problems=market_problems(tx.store,check,cmd.action=="submit" || cmd.action=="approve" || cmd.action=="clarify",f,cmd.now);
        if len(problems)>0 { return err(failure_text(service.Failed { code: "BAD_REQUEST",problems: problems,detail: "" })); }
    }
    if cmd.action=="submit" || cmd.action=="clarify" {
        m.terms_version+=1;
        m.terms_hash=domain.terms_hash(m,f.source);
        if cmd.action=="submit" { m.submitted_by=cmd.actor_id; m.approved_by=""; }
    }
    if cmd.action=="approve" || cmd.action=="reject" {
        let dr=decision(c,m,cmd,d);
        guard let _d=dr else let e=err_of(dr) { return err(failure_text(service.failure(e,""))); }
        if cmd.action=="approve" { m.approved_by=cmd.actor_id; }
    }
    if cmd.action=="request-changes" {
        let sr=approvals.stale(c,"market_open",m.id,cmd.reason,cmd.now,d);
        guard let _s=sr else let e=err_of(sr) { return err(failure_text(service.failure("UNAVAILABLE",e))); }
    }
    if cmd.action=="suspend" { m.suspended_at=cmd.now; m.suspend_reason=cmd.reason; m.status_note=cmd.reason; }
    if cmd.action=="resume" { m.status_note=""; }
    if cmd.action=="advance" {
        if m.status=="APPROVED" {
            m.status="FUNDING";
            if m.liquidity_request>0 {
                let rq=approvals.request(c,"liquidity","market",m.id,m.terms_hash,m.created_by,m.terms_version,1,"Initial liquidity",cmd.now,d);
                guard let _q=rq else let e=err_of(rq) { return err(failure_text(service.failure("UNAVAILABLE",e))); }
            }
        } else if m.status=="FUNDING" {
            if m.open_at>cmd.now || m.close_at<=cmd.now || f.facts.season_status!="ACTIVE" || !f.facts.source_approved {
                return err(failure_text(service.failure("INVALID_TRANSITION","")));
            }
            let authorized: result[[Found],str]=zokor.conn_query_all(c,
                "select exists(select 1 from approvals a join approval_applications p on p.approval_id=a.id " +
                "where a.kind='market_open' and a.subject_id=$1::uuid and a.payload_hash=$2 and a.status='approved' " +
                "and a.decided_by=nullif($3,'')::uuid) as present",
                [pg.arg_text(m.id),pg.arg_text(m.terms_hash),pg.arg_text(m.approved_by)],d);
            guard let approved=authorized else let e=err_of(authorized) { return err(failure_text(service.failure("UNAVAILABLE",e))); }
            if !approved[0].present || domain.terms_hash(m,f.source)!=m.terms_hash { return err(failure_text(service.failure("STALE_APPROVAL",""))); }
            if m.liquidity_request>0 {
                let funded: result[[Found],str]=zokor.conn_query_all(c,
                    "select exists(select 1 from approvals a join approval_applications p on p.approval_id=a.id " +
                    "where a.kind='liquidity' and a.subject_id=$1::uuid and a.payload_hash=$2 and a.status='approved') as present",
                    [pg.arg_text(m.id),pg.arg_text(m.terms_hash)],d);
                guard let ready=funded else let e=err_of(funded) { return err(failure_text(service.failure("UNAVAILABLE",e))); }
                if !ready[0].present { return err(failure_text(service.failure("INVALID_TRANSITION",""))); }
            }
            let wallets=ledger_store.open_market_wallets(c,m.season_id,m.id,d);
            guard let _opened=wallets else let e=err_of(wallets) { return err(failure_text(service.failure("UNAVAILABLE",e))); }
            m.status="OPEN"; m.opened_at=cmd.now;
        } else if (m.status=="OPEN" || m.status=="SUSPENDED") &&
            (m.close_at<=cmd.now || f.facts.season_status!="ACTIVE" || f.facts.season_end<=cmd.now) {
            m.status="CLOSED";
        } else if m.status=="CLOSED" { m.status="RESOLUTION_PENDING"; m.status_note="Collecting results"; }
        else { return err(failure_text(service.failure("INVALID_TRANSITION",""))); }
    }
    if m.status=="CLOSED" && m.closed_at==0 { m.closed_at=cmd.now; }
    if cmd.action!="create" { m.version+=1; }
    m.updated_at=cmd.now;
    let saved=save(c,m,cmd.action=="create",cmd.version,d);
    guard let changed=saved else let e=err_of(saved) { return err(failure_text(service.failure("UNAVAILABLE",e))); }
    if !changed { return err(failure_text(service.failure("STALE_VERSION",""))); }
    if cmd.action=="submit" || cmd.action=="clarify" {
        let frozen=freeze(c,m,f.source,cmd.reason,cmd.actor_id,cmd.now,d);
        guard let _f=frozen else let e=err_of(frozen) { return err(failure_text(service.failure("UNAVAILABLE",e))); }
        if cmd.action=="submit" {
            let rq=approvals.request(c,"market_open","market",m.id,m.terms_hash,cmd.actor_id,m.terms_version,1,cmd.reason,cmd.now,d);
            guard let _q=rq else let e=err_of(rq) { return err(failure_text(service.failure("UNAVAILABLE",e))); }
        }
    }
    let recorded=record(c,m,cmd,previous,d);
    guard let _r=recorded else let e=err_of(recorded) { return err(failure_text(service.failure("UNAVAILABLE",e))); }
    return ok(m);
}

fn mutate(s: Store, command: service.Command) -> result[domain.Market,service.Failed] {
    if command.action=="advance" && len(command.actor_id)==0 {
        let fast=fast_advance(s,command);
        guard let found=fast else let e=err_of(fast) { return err(service.failure("UNAVAILABLE",e)); }
        if let m=found { return ok(m); }
    }
    let r=zokor.transaction(s.pool,Mutation { store:s,command:command },mutate_tx,deadline(s));
    guard let m=r else let e=err_of(r) { return err(parse_failure(e)); }
    return ok(m);
}

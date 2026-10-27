import "crypto";
import "encoding";
import "pg";
import "proc";
import "redis";
import "strings";
import "time";
import "timez";
import "zokor";
import "../domain" as domain;
import "../service" as service;
import "../../ledger/store" as ledger_store;

gc struct Rig { base: pg.Pool, owner: pg.Pool, store: Store, name: str, author: str, curator: str, other: str, season: str, source: str }
gc struct TextRow { value: str }
gc struct NumberRow { value: int }

fn dl() -> until { return until_of(time.mono()+60000000000); }
fn pool_at(url: str) -> pg.Pool {
    let values: map[str]str={}; values["DATABASE_URL"]=url; values["DB_POOL_SIZE"]="16";
    let r=zokor.pg_from_config(zokor.config_from_values(values));
    guard let pool=r else let e=err_of(r) { panic(e); }
    return pool;
}
fn run(pool: pg.Pool,sql: str,args: [pg.Arg]) {
    let r=pg.pool_query(pool,sql,args,dl());
    guard let _rows=r else let e=err_of(r) { panic(e); }
}
fn text(pool: pg.Pool,sql: str,args: [pg.Arg]) -> str {
    let r: result[[TextRow],str]=zokor.query_all(pool,sql,args,dl());
    guard let rows=r else let e=err_of(r) { panic(e); }
    return rows[0].value;
}
fn number(pool: pg.Pool,sql: str,args: [pg.Arg]) -> int {
    let r: result[[NumberRow],str]=zokor.query_all(pool,sql,args,dl());
    guard let rows=r else let e=err_of(r) { panic(e); }
    return rows[0].value;
}
fn account(pool: pg.Pool,name: str,role: str) -> str {
    let id=text(pool,"insert into accounts(username,status,email_verified_at) values($1,'ACTIVE',now()) returning id::text as value",[pg.arg_text(name)]);
    run(pool,"insert into account_roles(account_id,role) values($1::uuid,$2)",[pg.arg_text(id),pg.arg_text(role)]);
    return id;
}
fn rig() -> opt[Rig] {
    let owner_url=proc.getenv("TEST_DATABASE_URL") ?? "";
    let app_url=proc.getenv("TEST_APP_DATABASE_URL") ?? "";
    if len(owner_url)==0 || len(app_url)==0 { println("skip registry postgres tests (test database URLs not set)"); return none; }
    let rand=crypto.rand(6); guard let random_bytes=rand else { panic("rand"); }
    let name="say_market_"+encoding.hex_encode(random_bytes);
    let base=pool_at(owner_url);
    run(base,"create database "+name,[]);
    let owner=pool_at(strings.replace(owner_url,"/say_test?","/"+name+"?"));
    let migration=zokor.load_migrations("migrations",zokor.migration_limits());
    guard let files=migration else let e=err_of(migration) { panic(e); }
    let migrated=zokor.migrate(owner,files,dl());
    guard let _m=migrated else let e=err_of(migrated) { panic(e); }
    let app=pool_at(strings.replace(app_url,"/say_test?","/"+name+"?"));
    let author=account(owner,"creator","creator");
    let curator=account(owner,"curator","curator");
    let other=account(owner,"other","curator");
    let season=text(owner,"insert into seasons(ordinal,starts_at,ends_at,status) values(1,'1970-01-01','1970-01-15','ACTIVE') returning id::text as value",[]);
    let source=text(owner,"insert into resolution_sources(name,url_pattern,kind,approved,created_by,approved_by,approved_at) " +
        "values('Approved test capture','https://example.test/results','html',true,$1::uuid,$2::uuid,now()) returning id::text as value",
        [pg.arg_text(author),pg.arg_text(curator)]);
    let absent: opt[redis.Pool]=none;
    let coordinator=ledger_store.new_postgres(app,absent,10000000000,50000000);
    let zr=timez.load_zone("Africa/Lagos"); guard let zone=zr else { panic("zone"); }
    return some(Rig { base:base,owner:owner,store:on_postgres(app,10000000000,coordinator,zone).context,name:name,
        author:author,curator:curator,other:other,season:season,source:source });
}
fn close(r: Rig) {
    zokor.pg_close(r.store.pool); zokor.pg_close(r.owner);
    run(r.base,"drop database "+r.name+" with (force)",[]);
    zokor.pg_close(r.base);
}
fn full_patch(r: Rig) -> domain.Patch {
    let p=domain.empty_patch();
    p.question=some("Will Enyimba win the Sunday fixture?");
    p.category_id=some("00000000-0000-4000-a000-000000000101");
    p.season_id=some(r.season); p.resolution_source_id=some(r.source);
    p.yes_if=some("The official final result is an Enyimba win.");
    p.no_if=some("The official final result is not an Enyimba win.");
    p.edge_cases=some("A postponed or abandoned fixture is reviewed for a void.");
    p.open_at=some(2000); p.close_at=some(10000000); p.resolve_by=some(14000000);
    p.redemption_units=some(100); p.min_price=some(1); p.max_price=some(99); p.opening_price=some(50);
    return p;
}
fn cmd(action: str,id: str,actor: str,version: int,p: domain.Patch,now: int) -> service.Command {
    return service.Command { action:action,id:id,actor_id:actor,version:version,patch:p,reason:"Test operator reason",now:now };
}
fn changed(r: Rig,c: service.Command) -> domain.Market {
    let result_=mutate(r.store,c);
    guard let m=result_ else let f=err_of(result_) { panic(f.code+": "+f.detail); }
    return m;
}
fn run_change(s: Store,c: service.Command) -> result[domain.Market,service.Failed] { return mutate(s,c); }

fn test_transactional_lifecycle_and_database_economic_lock() {
    guard let r=rig() else { return; }
    let id="11111111-1111-4111-a111-111111111111";
    let draft_=changed(r,cmd("create",id,r.author,0,full_patch(r),2000));
    assert(draft_.version==1 && draft_.status=="DRAFT");
    let submitted=changed(r,cmd("submit",id,r.author,1,domain.empty_patch(),2000));
    assert(submitted.status=="REVIEW" && submitted.terms_version==1);
    run(r.owner,"insert into account_roles(account_id,role) values($1::uuid,'super_admin')",[pg.arg_text(r.author)]);
    let denied=mutate(r.store,cmd("approve",id,r.author,2,domain.empty_patch(),2000));
    if let _m=denied { panic("self approval accepted"); } else let f=err_of(denied) { assert(f.code=="SELF_APPROVAL_FORBIDDEN",f.code); }
    let approved=changed(r,cmd("approve",id,r.curator,2,domain.empty_patch(),2000));
    assert(approved.status=="APPROVED" && approved.approved_by==r.curator);
    let funding=changed(r,cmd("advance",id,"",3,domain.empty_patch(),2000));
    let opened=changed(r,cmd("advance",id,"",funding.version,domain.empty_patch(),2000));
    assert(opened.status=="OPEN" && opened.opened_at==2000);
    assert(number(r.owner,
        "select count(*)::bigint as value from wallets where season_id=$1::uuid and owner_kind='system' and ((owner_id like 'system:collateral:%' and asset_key='SEDI') or (owner_id like 'system:shares:%' and (asset_key like 'YES:%' or asset_key like 'NO:%')))",
        [pg.arg_text(r.season)])==3);
    let raw=pg.pool_query(r.store.pool,"update markets set redemption_units=200,min_price=1,max_price=199 where id=$1::uuid",[pg.arg_text(id)],dl());
    if let _rows=raw { panic("raw SQL rewrote open economics"); } else let e=err_of(raw) { assert(strings.contains(e,"LOCKED_AFTER_OPEN"),e); }
    run(r.owner,"insert into account_roles(account_id,role) values($1::uuid,'super_admin')",[pg.arg_text(r.curator)]);
    let clarification=domain.empty_patch(); clarification.question=some("Will Enyimba win the confirmed Sunday fixture?");
    let clarified=changed(r,cmd("clarify",id,r.curator,opened.version,clarification,3000));
    assert(clarified.terms_version==2 && clarified.redemption_units==100);
    let history_count=number(r.owner,"select count(*)::bigint as value from market_terms_versions where market_id=$1::uuid",[pg.arg_text(id)]);
    assert(history_count==2);
    assert(text(r.owner,"select created_by::text as value from market_terms_versions where market_id=$1::uuid and terms_version=2",[pg.arg_text(id)])==r.curator);
    let suspended=changed(r,cmd("suspend",id,r.curator,clarified.version,domain.empty_patch(),4000));
    let closed=changed(r,cmd("advance",id,"",suspended.version,domain.empty_patch(),10000000));
    assert(closed.status=="CLOSED");
    let pending_=changed(r,cmd("advance",id,"",closed.version,domain.empty_patch(),10000000));
    assert(pending_.status=="RESOLUTION_PENDING");
    assert(number(r.owner,"select count(*)::bigint as value from audit_events where target_type='market' and target_id=$1",[pg.arg_text(id)])==pending_.version);
    close(r);
}

fn test_creator_isolation_expired_resume_and_approval_fact_privileges() {
    guard let r=rig() else { return; }
    let id="33333333-3333-4333-a333-333333333333";
    let m=changed(r,cmd("create",id,r.author,0,full_patch(r),2000));
    let other_creator=account(r.owner,"another.creator","creator");
    let private_=find(r.store,id,other_creator);
    guard let found=private_ else let f=err_of(private_) { panic(f.code+f.detail); }
    if let _m=found { panic("creator read another creator draft"); }
    let anonymous=find(r.store,id,"");
    guard let hidden=anonymous else { panic("find"); }
    if let _m=hidden { panic("draft leaked publicly"); }
    let bad=mutate(r.store,cmd("edit",id,other_creator,m.version,full_patch(r),2000));
    if let _m=bad { panic("creator edited another draft"); }
    let review=changed(r,cmd("submit",id,r.author,1,domain.empty_patch(),2000));
    let changes=changed(r,cmd("request-changes",id,r.curator,review.version,domain.empty_patch(),2000));
    assert(text(r.owner,"select status as value from approvals where subject_id=$1::uuid order by created_at limit 1",[pg.arg_text(id)])=="stale");
    let again=changed(r,cmd("submit",id,r.author,changes.version,domain.empty_patch(),2000));
    let approved=changed(r,cmd("approve",id,r.curator,again.version,domain.empty_patch(),2000));
    let funding=changed(r,cmd("advance",id,"",approved.version,domain.empty_patch(),2000));
    let opened=changed(r,cmd("advance",id,"",funding.version,domain.empty_patch(),2000));
    let paused=changed(r,cmd("suspend",id,r.curator,opened.version,domain.empty_patch(),3000));
    let expired=changed(r,cmd("resume",id,r.curator,paused.version,domain.empty_patch(),paused.close_at));
    assert(expired.status=="CLOSED");
    immutable(r.store.pool,"update approval_requests set reason='tampered' where false");
    immutable(r.store.pool,"delete from market_terms_versions where false");
    immutable(r.store.pool,"delete from audit_events where false");
    close(r);
}

fn immutable(pool: pg.Pool,sql: str) {
    let args: [pg.Arg]=[];
    let r=pg.pool_query(pool,sql,args,dl());
    if let _rows=r { panic("immutable fact was writable"); }
}

fn test_parallel_edits_and_approvals_have_one_winner() {
    guard let r=rig() else { return; }
    let id="22222222-2222-4222-a222-222222222222";
    let m=changed(r,cmd("create",id,r.author,0,full_patch(r),2000));
    let first=domain.empty_patch(); first.question=some("Will Enyimba win their scheduled Sunday fixture?");
    let jobs=[spawn run_change(r.store,cmd("edit",id,r.author,1,first,2000))];
    for i in 1..10 { push(jobs,spawn run_change(r.store,cmd("edit",id,r.author,1,first,2000))); }
    let wins=0;
    for job in jobs {
        let joined=join_wait(job); guard let result_=joined else { panic("edit task panic"); }
        if let _m=result_ { wins+=1; } else let f=err_of(result_) { assert(f.code=="STALE_VERSION",f.code+f.detail); }
    }
    assert(wins==1);
    let submitted=changed(r,cmd("submit",id,r.author,2,domain.empty_patch(),2000));
    let a=spawn run_change(r.store,cmd("approve",id,r.curator,submitted.version,domain.empty_patch(),2000));
    let b=spawn run_change(r.store,cmd("approve",id,r.other,submitted.version,domain.empty_patch(),2000));
    wins=0;
    for job in [a,b] {
        let joined=join_wait(job); guard let result_=joined else { panic("approval task panic"); }
        if let _m=result_ { wins+=1; } else let f=err_of(result_) { assert(f.code=="STALE_VERSION",f.code+f.detail); }
    }
    assert(wins==1);
    assert(number(r.owner,"select count(*)::bigint as value from approval_decisions d join approval_requests a on a.id=d.approval_id where a.subject_id=$1::uuid",[pg.arg_text(id)])==1);
    close(r);
}

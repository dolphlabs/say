import "crypto";
import "encoding";
import "json";
import "pg";
import "proc";
import "strings";
import "time";
import "zokor";
import "../domain" as core;
import "../service" as service;
import "../../platform/db" as db;
import "../../platform/cache" as cache;

gc struct SchemaRig { base: pg.Pool, owner: pg.Pool, app: pg.Pool, name: str, market: str, season: str, node: str }
gc struct ScalarText { value: str }
gc struct ScalarInt { value: int }
gc struct Reserved { command_ref: str, bucket: int, existing: bool }
gc struct EnqueueArg { rig: SchemaRig, ref: str, kind: str, source: str, mismatch: bool }
gc struct FinalArg { rig: SchemaRig, ref: str, input: str, record: str, previous: str, next: str, node: str, epoch: int, pause: bool, null_seq: bool }

fn schema_deadline() -> until { return until_of(time.mono()+30000000000); }
fn schema_pool(url: str) -> pg.Pool {
    let r=pg.new_pool(url,12); guard let p=r else let e=err_of(r) { panic(e); } return p;
}
fn schema_exec(pool: pg.Pool,sql: str,args: [pg.Arg]) {
    let r=pg.pool_query(pool,sql,args,schema_deadline()); guard let _rows=r else let e=err_of(r) { panic(e); }
}
fn schema_text(pool: pg.Pool,sql: str,args: [pg.Arg]) -> str {
    let r: result[[ScalarText],str]=zokor.query_all(pool,sql,args,schema_deadline()); guard let rows=r else let e=err_of(r) { panic(e); }
    return rows[0].value;
}
fn schema_int(pool: pg.Pool,sql: str,args: [pg.Arg]) -> int {
    let r: result[[ScalarInt],str]=zokor.query_all(pool,sql,args,schema_deadline()); guard let rows=r else let e=err_of(r) { panic(e); }
    return rows[0].value;
}
fn schema_uuid(r: SchemaRig) -> str { return schema_text(r.owner,"select gen_random_uuid()::text as value",[]); }
fn schema_policy(r: SchemaRig) -> core.Policy {
    return core.Policy { market_id:r.market,season_id:r.season,V:100,min_price:1,max_price:99,tick:1,max_order_qty:10000,min_order_notional:2 };
}
fn schema_rig() -> opt[SchemaRig] {
    let owner_url=proc.getenv("TEST_DATABASE_URL") ?? ""; let app_url=proc.getenv("TEST_APP_DATABASE_URL") ?? "";
    if owner_url=="" || app_url=="" { println("skip runtime schema tests (test URLs not set)"); return none; }
    let random=crypto.rand(6); guard let random_bytes=random else { panic("rand"); }
    let name="say_runtime_"+encoding.hex_encode(random_bytes); let base=schema_pool(owner_url);
    schema_exec(base,"create database "+name,[]);
    let owner=schema_pool(strings.replace(owner_url,"/say_test?","/"+name+"?"));
    let loaded=zokor.load_migrations("migrations",zokor.migration_limits()); guard let files=loaded else let e=err_of(loaded) { panic(e); }
    let migrated=zokor.migrate(owner,files,schema_deadline()); guard let _count=migrated else let e=err_of(migrated) { panic(e); }
    let app=schema_pool(strings.replace(app_url,"/say_test?","/"+name+"?"));
    let account=schema_text(owner,"insert into accounts(username,status) values('schema.creator','ACTIVE') returning id::text as value",[]);
    let season=schema_text(owner,"insert into seasons(ordinal,starts_at,ends_at,status) values(1,now()-interval '1 hour',now()-interval '1 hour'+interval '14 days','ACTIVE') returning id::text as value",[]);
    let market=schema_text(owner,"insert into markets(slug,question,season_id,created_by,status,redemption_units,min_price,max_price,tick,fee_units,min_order_notional) " +
        "values('schema-fixture','Will this schema fixture preserve its invariants?',$1::uuid,$2::uuid,'DRAFT',100,1,99,1,1,2) returning id::text as value",[pg.arg_text(season),pg.arg_text(account)]);
    let node=schema_text(owner,"insert into runtime_nodes(id,name,live_until) values(gen_random_uuid(),'schema',clock_timestamp()+interval '1 hour') returning id::text as value",[]);
    let r=SchemaRig { base:base,owner:owner,app:app,name:name,market:market,season:season,node:node };
    let created=core.new_book(schema_policy(r),4,0); guard let b=created else { panic("book"); }
    schema_exec(owner,"update markets set owner_epoch=1,runtime_verified_epoch=1,runtime_status='READY',rolling_hash=$2 where id=$1::uuid",[pg.arg_text(market),pg.arg_text(core.digest_text(b.digest.data,0))]);
    schema_exec(owner,"insert into market_owners(market_id,node_id,epoch,lease_until) values($1::uuid,$2::uuid,1,clock_timestamp()+interval '1 hour')",[pg.arg_text(market),pg.arg_text(node)]);
    schema_exec(app,"select say_runtime_prepare_queue($1::uuid,2,2)",[pg.arg_text(market)]);
    return some(r);
}
fn schema_close(r: SchemaRig) {
    pg.pool_close(r.app); pg.pool_close(r.owner);
    schema_exec(r.base,"drop database "+r.name+" with (force)",[]); pg.pool_close(r.base);
}
fn enqueue_schema_tx(c: pg.Conn,a: EnqueueArg) -> result[Reserved,str] {
    let args=[pg.arg_text(a.rig.market),pg.arg_text(a.ref),pg.arg_text(a.kind),pg.arg_text(a.source)];
    let read: result[[Reserved],str]=zokor.conn_query_all(c,"select command_ref::text as command_ref,bucket::bigint as bucket,existing from say_runtime_reserve($1::uuid,$2::uuid,$3,$4,0)",args,schema_deadline());
    guard let rows=read else let e=err_of(read) { return err(e); }
    let reserved=rows[0]; if reserved.existing { return ok(reserved); }
    let kind=a.kind; if a.mismatch { kind="Suspend"; }
    let inserted=pg.query(c,"select say_runtime_enqueue($1::uuid,$2::uuid,$3,null,$4,'{}'::jsonb)",
        [pg.arg_text(a.rig.market),pg.arg_text(a.ref),pg.arg_text(kind),pg.arg_text(a.source)],schema_deadline());
    guard let _inserted=inserted else let e=err_of(inserted) { return err(e); }
    return ok(reserved);
}
fn schema_enqueue(r: SchemaRig,ref: str,kind: str,source: str,mismatch: bool) -> result[Reserved,str] {
    return zokor.transaction(r.app,EnqueueArg { rig:r,ref:ref,kind:kind,source:source,mismatch:mismatch },enqueue_schema_tx,schema_deadline());
}
fn finalize_schema_tx(c: pg.Conn,a: FinalArg) -> result[int,str] {
    let no_args: [pg.Arg]=[];
    let season=pg.query(c,"select id from seasons where id=$1::uuid for share",[pg.arg_text(a.rig.season)],schema_deadline()); guard let _s=season else let e=err_of(season) { return err(e); }
    let halt=pg.query(c,"select id from trading_halt where id=1 for share",no_args,schema_deadline()); guard let _h=halt else let e=err_of(halt) { return err(e); }
    let market=pg.query(c,"select id from markets where id=$1::uuid for update",[pg.arg_text(a.rig.market)],schema_deadline()); guard let _m=market else let e=err_of(market) { return err(e); }
    let budget=pg.query(c,"select say_runtime_lock_permit($1::uuid,$2::uuid) as locked",[pg.arg_text(a.rig.market),pg.arg_text(a.ref)],schema_deadline()); guard let _b=budget else let e=err_of(budget) { return err(e); }
    if a.pause { let slept=pg.query(c,"select pg_sleep(0.12)",no_args,schema_deadline()); guard let _slept=slept else let e=err_of(slept) { return err(e); } }
    let advanced=pg.query(c,"update markets set committed_seq=1,rolling_hash=$2 where id=$1::uuid and committed_seq=0",[pg.arg_text(a.rig.market),pg.arg_text(a.next)],schema_deadline()); guard let _a=advanced else let e=err_of(advanced) { return err(e); }
    let sequence="1"; if a.null_seq { sequence=""; }
    let completed=pg.query(c,"update market_commands set seq=nullif($2,'')::bigint,state='DONE',resolved_input=$3::jsonb,transition=$4::jsonb,previous_hash=$5,state_hash=$6,node_id=$7::uuid,owner_epoch=$8,executed_at=clock_timestamp(),completed_at=clock_timestamp() where id=$1::uuid",
        [pg.arg_text(a.ref),pg.arg_text(sequence),pg.arg_text(a.input),pg.arg_text(a.record),pg.arg_text(a.previous),pg.arg_text(a.next),pg.arg_text(a.node),pg.arg_int(a.epoch)],schema_deadline());
    guard let _c=completed else let e=err_of(completed) { return err(e); }
    return ok(1);
}
fn schema_final_arg(r: SchemaRig,ref: str) -> FinalArg {
    let created=core.new_book(schema_policy(r),4,0); guard let b=created else { panic("book"); }
    let w=core.new_workspace(&b,4);
    let cmd=core.Command { kind:"Snapshot",seq:1,ref:ref,order:core.empty_order(),order_id:"",account_id:"",system:true,reason:"" };
    assert(core.plan(&b,cmd,&mut w)==""); let converted=service.record(&b,&mut w); guard let record=converted else { panic("record"); }
    return FinalArg { rig:r,ref:ref,input:json.encode(cmd),record:json.encode(record),previous:record.prev_hash,next:record.state_hash,node:r.node,epoch:1,pause:false,null_seq:false };
}

fn test_queue_claims_are_bounded_deduplicated_and_keep_close_capacity() {
    guard let r=schema_rig() else { return; }
    let first=schema_uuid(r); let one=schema_enqueue(r,first,"Snapshot","first",false); guard let a=one else let e=err_of(one) { panic(e); }
    let duplicate=schema_enqueue(r,schema_uuid(r),"Snapshot","first",false); guard let b=duplicate else { panic("dedupe"); }
    assert(b.existing && b.command_ref==a.command_ref);
    let two=schema_enqueue(r,schema_uuid(r),"Suspend","second",false); guard let _two=two else { panic("second"); }
    let full=schema_enqueue(r,schema_uuid(r),"Resume","third",false);
    if let _bad=full { panic("queue exceeded bound"); } else let e=err_of(full) { assert(strings.contains(e,"SAY_QUEUE_FULL"),e); }
    let close=schema_enqueue(r,schema_uuid(r),"Close","close",false); guard let closed=close else let e=err_of(close) { panic(e); }
    assert(closed.bucket==17 && schema_int(r.owner,"select count(*)::bigint as value from market_queue_claims",[])==3);
    let forbidden=pg.pool_query(r.app,"update market_queue_budgets set remaining=capacity",[],schema_deadline());
    if let _bad=forbidden { panic("app bypassed queue budget"); }
    schema_close(r);
}

fn test_deferred_lease_and_epoch_fence_roll_back_sequence_and_permit() {
    guard let r=schema_rig() else { return; }
    let ref=schema_uuid(r); let queued=schema_enqueue(r,ref,"Snapshot","fence",false); guard let _q=queued else { panic("enqueue"); }
    let a=schema_final_arg(r,ref); a.pause=true;
    schema_exec(r.owner,"update market_owners set lease_until=clock_timestamp()+interval '80 milliseconds' where market_id=$1::uuid",[pg.arg_text(r.market)]);
    let expired=zokor.transaction(r.app,a,finalize_schema_tx,schema_deadline());
    if let _bad=expired { panic("expired owner committed"); } else let e=err_of(expired) { assert(strings.contains(e,"SAY_OWNER_FENCED"),e); }
    assert(schema_int(r.owner,"select committed_seq as value from markets where id=$1::uuid",[pg.arg_text(r.market)])==0);
    assert(schema_int(r.owner,"select remaining::bigint as value from market_queue_budgets where market_id=$1::uuid and bucket=16",[pg.arg_text(r.market)])==1);
    let successor=schema_text(r.owner,"insert into runtime_nodes(id,name,live_until) values(gen_random_uuid(),'successor',clock_timestamp()+interval '1 hour') returning id::text as value",[]);
    schema_exec(r.owner,"update market_owners set node_id=$2::uuid,epoch=2,lease_until=clock_timestamp()+interval '1 hour' where market_id=$1::uuid",[pg.arg_text(r.market),pg.arg_text(successor)]);
    schema_exec(r.owner,"update markets set owner_epoch=2,runtime_verified_epoch=2 where id=$1::uuid",[pg.arg_text(r.market)]);
    a.pause=false;
    let stale=zokor.transaction(r.app,a,finalize_schema_tx,schema_deadline());
    if let _bad=stale { panic("stale epoch committed"); } else let e=err_of(stale) { assert(strings.contains(e,"SAY_OWNER_FENCED"),e); }
    a.node=successor; a.epoch=2;
    let finished=zokor.transaction(r.app,a,finalize_schema_tx,schema_deadline()); guard let _done=finished else let e=err_of(finished) { panic(e); }
    assert(schema_int(r.owner,"select remaining::bigint as value from market_queue_budgets where market_id=$1::uuid and bucket=16",[pg.arg_text(r.market)])==2);
    let rewrite=pg.pool_query(r.app,"update market_commands set payload='{}'::jsonb where id=$1::uuid",[pg.arg_text(ref)],schema_deadline());
    if let _bad=rewrite { panic("finalized command was mutable"); } else let e=err_of(rewrite) { assert(strings.contains(e,"SAY_COMMAND_IMMUTABLE"),e); }
    schema_close(r);
}

fn test_nullable_final_command_and_mismatched_claim_cannot_commit() {
    guard let r=schema_rig() else { return; }
    let mismatch=schema_enqueue(r,schema_uuid(r),"Snapshot","mismatch",true);
    if let _bad=mismatch { panic("changed reserved command type"); } else let e=err_of(mismatch) { assert(strings.contains(e,"SAY_QUEUE_CLAIM_IDENTITY"),e); }
    assert(schema_int(r.owner,"select count(*)::bigint as value from market_queue_claims",[])==0);
    let ref=schema_uuid(r); let queued=schema_enqueue(r,ref,"Snapshot","nullable",false); guard let _q=queued else { panic("enqueue"); }
    let a=schema_final_arg(r,ref); a.null_seq=true;
    let rejected=zokor.transaction(r.app,a,finalize_schema_tx,schema_deadline());
    if let _bad=rejected { panic("null sequence bypassed final state check"); } else let e=err_of(rejected) { assert(pg.sqlstate(e)=="23514",e); }
    assert(schema_int(r.owner,"select committed_seq as value from markets where id=$1::uuid",[pg.arg_text(r.market)])==0);
    schema_close(r);
}

fn test_legacy_publisher_does_not_claim_private_runtime_events() {
    guard let r=schema_rig() else { return; }
    let account=schema_text(r.owner,"select id::text as value from accounts limit 1",[]);
    schema_exec(r.app,"insert into outbox_events(type,payload) values('legacy.fixture','{}')",[]);
    schema_exec(r.app,"insert into outbox_events(market_id,market_seq,type,payload,audience,account_id,event_ordinal,owner_epoch) values($1::uuid,1,'order.updated','{}','account',$2::uuid,0,1)",[pg.arg_text(r.market),pg.arg_text(account)]);
    let published=db.publish_outbox(db.Db { pool:r.app },cache.in_memory(),10,10000000000); guard let count=published else let e=err_of(published) { panic(e); }
    assert(count==1);
    assert(schema_int(r.owner,"select count(*)::bigint as value from outbox_events where audience='account' and published_at is null",[])==1);
    schema_close(r);
}

fn test_runtime_ownership_renews_fences_and_releases_leases() {
    guard let r=schema_rig() else { return; }
    let ownership=service.new_ownership(ownership_store(new_postgres(r.app,10000000000)));
    let next_node=schema_uuid(r);
    let registered=service.register_node(ownership,next_node,"successor",15);
    guard let did_register=registered else let e=err_of(registered) { panic(e); }
    assert(did_register);

    let same_node=service.acquire(ownership,r.market,r.node,10);
    guard let same_claim=same_node else let e=err_of(same_node) { panic(e); }
    assert(!same_claim.acquired && same_claim.renewed && same_claim.epoch==1);

    let competing=service.acquire(ownership,r.market,next_node,10);
    guard let active_claim=competing else let e=err_of(competing) { panic(e); }
    assert(!active_claim.acquired && !active_claim.renewed && active_claim.node_id==r.node);

    schema_exec(r.owner,"update market_owners set lease_until=clock_timestamp()-interval '1 second' where market_id=$1::uuid",[pg.arg_text(r.market)]);
    let takeover=service.acquire(ownership,r.market,next_node,10);
    guard let new_claim=takeover else let e=err_of(takeover) { panic(e); }
    assert(new_claim.acquired && !new_claim.renewed && new_claim.epoch==2);

    let stale_release=service.release(ownership,r.market,r.node,1);
    guard let stale_released=stale_release else let e=err_of(stale_release) { panic(e); }
    assert(!stale_released);

    let no_markets: [str]=[];
    let no_epochs: [int]=[];
    let node_heartbeat=service.heartbeat(ownership,next_node,15,no_markets,no_epochs);
    guard let live=node_heartbeat else let e=err_of(node_heartbeat) { panic(e); }
    assert(live.node_live && len(live.markets)==0);
    let market_heartbeat=service.heartbeat(ownership,next_node,15,[r.market],[2]);
    guard let renewed=market_heartbeat else let e=err_of(market_heartbeat) { panic(e); }
    assert(renewed.node_live && len(renewed.markets)==1);
    assert(renewed.markets[0].market_id==r.market && renewed.markets[0].renewed);

    schema_exec(r.owner,"update markets set owner_epoch=3 where id=$1::uuid",[pg.arg_text(r.market)]);
    let mismatched_heartbeat=service.heartbeat(ownership,next_node,15,[r.market],[2]);
    guard let mismatch= mismatched_heartbeat else let e=err_of(mismatched_heartbeat) { panic(e); }
    assert(mismatch.node_live && len(mismatch.markets)==1 && !mismatch.markets[0].renewed);
    let mismatched_claim=service.acquire(ownership,r.market,next_node,10);
    if let _claim=mismatched_claim { panic("owner epoch mismatch was accepted"); }
    else let e=err_of(mismatched_claim) { assert(e=="OWNER_EPOCH_MISMATCH",e); }
    schema_exec(r.owner,"update markets set owner_epoch=2 where id=$1::uuid",[pg.arg_text(r.market)]);

    let released=service.release(ownership,r.market,next_node,2);
    guard let did_release=released else let e=err_of(released) { panic(e); }
    assert(did_release);
    let expired_release=service.release(ownership,r.market,next_node,2);
    guard let did_expire=expired_release else let e=err_of(expired_release) { panic(e); }
    assert(!did_expire);
    schema_close(r);
}

fn test_pending_loader_uses_committed_market_command_frontier() {
    guard let r=schema_rig() else { return; }
    let first_ref=schema_uuid(r);
    let first=schema_enqueue(r,first_ref,"Snapshot","frontier.first",false);
    guard let _first=first else { panic("first command enqueue failed"); }
    let second_ref=schema_uuid(r);
    let second=schema_enqueue(r,second_ref,"Suspend","frontier.second",false);
    guard let _second=second else { panic("second command enqueue failed"); }

    let queue=service.new_queue(command_queue(new_postgres(r.app,10000000000)));
    let first_batch_result=service.load_pending(queue,r.market,0,1);
    guard let first_batch=first_batch_result else let e=err_of(first_batch_result) { panic(e); }
    assert(len(first_batch.commands)==1);
    assert(first_batch.commands[0].command_ref==first_ref);
    assert(first_batch.commands[0].command_type=="Snapshot");
    assert(first_batch.commands[0].payload=="{}");
    assert(first_batch.frontier>=first_batch.commands[0].command_id);

    let second_batch_result=service.load_pending(queue,r.market,first_batch.commands[0].command_id,64);
    guard let second_batch=second_batch_result else let e=err_of(second_batch_result) { panic(e); }
    assert(len(second_batch.commands)==1);
    assert(second_batch.commands[0].command_ref==second_ref);
    assert(second_batch.commands[0].command_type=="Suspend");
    assert(second_batch.frontier==first_batch.frontier);

    let empty_batch_result=service.load_pending(queue,r.market,second_batch.commands[0].command_id,64);
    guard let empty_batch=empty_batch_result else let e=err_of(empty_batch_result) { panic(e); }
    assert(len(empty_batch.commands)==0 && empty_batch.frontier==second_batch.frontier);
    schema_close(r);
}

fn test_command_queue_store_reserves_and_enqueues_idempotently() {
    guard let r=schema_rig() else { return; }
    let queue=service.new_queue(command_queue(new_postgres(r.app,10000000000)));
    let first_ref=schema_uuid(r);
    let command=service.EnqueueCommand {
        market_id:r.market,
        command_ref:first_ref,
        command_type:"Snapshot",
        order_id:"",
        source_key:"store.snapshot.once",
        payload:"{}",
        bucket_start:0
    };
    let first_result=service.enqueue_control(queue,command);
    guard let first=first_result else let e=err_of(first_result) { panic(e); }
    assert(!first.existing && first.command_ref==first_ref);

    command.command_ref=schema_uuid(r);
    let duplicate_result=service.enqueue_control(queue,command);
    guard let duplicate=duplicate_result else let e=err_of(duplicate_result) { panic(e); }
    assert(duplicate.existing && duplicate.command_ref==first_ref);
    assert(schema_int(r.owner,"select count(*)::bigint as value from market_commands where market_id=$1::uuid",[pg.arg_text(r.market)])==1);
    schema_close(r);
}

fn test_actor_writer_commits_transition_and_returns_queue_permit() {
    guard let r=schema_rig() else { return; }
    let ref=schema_uuid(r);
    let command=core.Command {
        kind:"Snapshot",seq:1,ref:ref,order:core.empty_order(),order_id:"",
        account_id:"",system:true,reason:""
    };
    let queue=service.new_queue(command_queue(new_postgres(r.app,10000000000)));
    let enqueue=service.enqueue_control(queue,service.EnqueueCommand {
        market_id:r.market,command_ref:ref,command_type:"Snapshot",order_id:"",
        source_key:"store.commit.snapshot",payload:json.encode(command),bucket_start:0
    });
    guard let _queued=enqueue else let e=err_of(enqueue) { panic(e); }

    let created=core.new_book(schema_policy(r),4,0);
    guard let book=created else { panic("book"); }
    let workspace=core.new_workspace(&book,4);
    assert(core.plan(&book,command,&mut workspace)=="");
    let converted=service.record(&book,&mut workspace);
    guard let transition=converted else { panic("transition"); }
    let postgres=new_postgres(r.app,10000000000);
    let committed=st_commit(postgres,transition,command,r.node,1);
    guard let confirmed=committed else let e=err_of(committed) { panic(e); }
    assert(confirmed);
    assert(schema_int(r.owner,"select committed_seq as value from markets where id=$1::uuid",[pg.arg_text(r.market)])==1);
    assert(schema_text(r.owner,"select state as value from market_commands where id=$1::uuid",[pg.arg_text(ref)])=="DONE");
    assert(schema_int(r.owner,"select remaining as value from market_queue_budgets where market_id=$1::uuid and bucket=16",[pg.arg_text(r.market)])==2);
    assert(schema_int(r.owner,"select committed_seq as value from market_book_views where market_id=$1::uuid",[pg.arg_text(r.market)])==1);
    assert(schema_text(r.owner,"select payload->>'health' as value from market_book_views where market_id=$1::uuid",[pg.arg_text(r.market)])=="READY");
    assert(schema_int(r.owner,"select (payload->>'pending_count')::bigint as value from market_book_views where market_id=$1::uuid",[pg.arg_text(r.market)])==0);
    let hydrated=service.ready_views(book_view_store(postgres),"",10);
    guard let views=hydrated else let e=err_of(hydrated) { panic(e); }
    assert(len(views)==1 && views[0].market_id==r.market && views[0].owner_epoch==1);
    assert(views[0].lease_until>views[0].as_of && views[0].health=="READY");
    let restored=service.recover_book(recovery_store(postgres),r.market,4);
    guard let recovered=restored else let e=err_of(restored) { panic(e); }
    assert(recovered.last_seq==1 && core.snapshot(&recovered).state_hash==transition.state_hash);
    schema_close(r);
}

fn test_recovery_store_loads_and_verifies_genesis_state() {
    guard let r=schema_rig() else { return; }
    let postgres=new_postgres(r.app,10000000000);
    let store=recovery_store(postgres);
    let recovered=service.recover_book(store,r.market,4);
    guard let book=recovered else let e=err_of(recovered) { panic(e); }
    assert(book.last_seq==0 && book.mode=="OPEN");
    assert(core.snapshot(&book).state_hash==schema_text(r.owner,
        "select rolling_hash as value from markets where id=$1::uuid",[pg.arg_text(r.market)]));
    schema_close(r);
}

fn test_snapshot_store_persists_checksum_and_recovers_snapshot() {
    guard let r=schema_rig() else { return; }
    let postgres=new_postgres(r.app,10000000000);
    let created=core.new_book(schema_policy(r),4,0);
    guard let book=created else { panic("snapshot book"); }
    let workspace=core.new_workspace(&book,4);
    assert(core.full_hash(&book,false,&mut workspace)=="");
    let state=core.snapshot(&book);
    let request=service.SnapshotWrite {
        market_id:r.market,node_id:r.node,committed_seq:0,state_hash:state.state_hash,
        full_hash:core.digest_text(workspace.hashes.data,64),payload:json.encode(state),owner_epoch:1
    };
    let saved=st_save_snapshot(postgres,request);
    guard let inserted=saved else let e=err_of(saved) { panic(e); }
    assert(inserted);
    assert(schema_int(r.owner,"select count(*)::bigint as value from market_snapshots where market_id=$1::uuid",[pg.arg_text(r.market)])==1);
    let recovered=service.recover_book(recovery_store(postgres),r.market,4);
    guard let restored=recovered else let e=err_of(recovered) { panic(e); }
    assert(restored.last_seq==0 && core.snapshot(&restored).state_hash==state.state_hash);
    schema_close(r);
}

fn test_read_store_executes_private_and_public_queries_and_buckets_history() {
    guard let r=schema_rig() else { return; }
    schema_exec(r.owner,
        "insert into market_price_points(market_id,minute_at,open_price,high_price,low_price,close_price,volume_units,first_seq,first_index,last_seq,last_index) "+
        "values($1::uuid,date_trunc('minute',clock_timestamp())-interval '2 minutes',40,45,38,42,10,1,0,1,0),"+
        "($1::uuid,date_trunc('minute',clock_timestamp())-interval '1 minute',42,43,41,43,5,2,0,2,0)",
        [pg.arg_text(r.market)]);
    let reads=read_store(new_postgres(r.app,10000000000));
    let account=schema_uuid(r);
    let order=service.read_order(reads,account,schema_uuid(r));
    guard let missing=order else let e=err_of(order) { panic(e); }
    if let _found=missing { panic("private order query returned a row"); }
    let orders=service.read_orders(reads,account,r.market,"all","",10);
    guard let page=orders else let e=err_of(orders) { panic(e); }
    assert(len(page.items)==0 && !page.has_more);
    let cursor_page=service.read_orders(reads,account,r.market,"all",schema_uuid(r),10);
    guard let after_cursor=cursor_page else let e=err_of(cursor_page) { panic(e); }
    assert(len(after_cursor.items)==0 && !after_cursor.has_more);
    let trades=service.read_trades(reads,r.market,0,0,10);
    guard let fills=trades else let e=err_of(trades) { panic(e); }
    assert(len(fills.items)==0 && !fills.has_more);
    let trade_cursor=service.read_trades(reads,r.market,100,0,10);
    guard let after_trade=trade_cursor else let e=err_of(trade_cursor) { panic(e); }
    assert(len(after_trade.items)==0 && !after_trade.has_more);
    let history=service.read_history(reads,r.market,3600,60);
    guard let candles=history else let e=err_of(history) { panic(e); }
    assert(len(candles)==2 && candles[0].open==40 && candles[0].high==45 && candles[0].volume==10);
    schema_close(r);
}

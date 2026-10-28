import "json";
import "pg";
import "zokor";
import "../domain" as core;
import "../service" as service;
import "../../ledger/service" as ledger;
import "../../ledger/store" as ledger_store;

gc struct RuntimeFund { rig: SchemaRig, account: str, amount: int }

fn runtime_fund_tx(conn: pg.Conn,arg: RuntimeFund) -> result[bool,str] {
    let batch=ledger.journal_batch();
    let rows=ledger.journal_rows();
    ledger.journal_entry(rows,"system","system:treasury","SEDI","free",0-arg.amount,"");
    ledger.journal_entry(rows,"user",arg.account,"SEDI","free",arg.amount,"");
    ledger.journal_append(batch,rows,"fixture:"+arg.account,"ADJUSTMENT",arg.rig.season,"","test",arg.account);
    let posted=ledger_store.post_many_encoded(conn,batch.transactions,schema_deadline());
    guard let _posted=posted else let e=err_of(posted) { return err(e); }
    return ok(true);
}

fn runtime_account(r: SchemaRig,amount: int) -> str {
    let id=schema_text(r.owner,"insert into accounts(username,status) values(gen_random_uuid()::text,'ACTIVE') returning id::text as value",[]);
    let funded=zokor.transaction(r.app,RuntimeFund { rig:r,account:id,amount:amount },runtime_fund_tx,schema_deadline());
    guard let _funded=funded else let e=err_of(funded) { panic(e); }
    return id;
}

fn runtime_setup(r: SchemaRig) {
    let source=schema_text(r.owner,
        "insert into resolution_sources(name,url_pattern,kind,created_by) select 'runtime fixture','https://example.test/result','json',created_by "+
        "from markets where id=$1::uuid returning id::text as value",[pg.arg_text(r.market)]);
    schema_exec(r.owner,"update markets set close_at=clock_timestamp()+interval '1 day',open_at=clock_timestamp()-interval '1 hour',"+
        "resolve_by=clock_timestamp()+interval '25 hours',category_id='00000000-0000-4000-a000-000000000101',"+
        "resolution_source_id=$2::uuid,terms_version=1,terms_hash=repeat('a',64),"+
        "rules=jsonb_build_object('yes_if','The independently verified outcome is yes.','no_if','The independently verified outcome is no.',"+
        "'edge_cases','Use the approved resolution source for all edge cases.') where id=$1::uuid",
        [pg.arg_text(r.market),pg.arg_text(source)]);
    schema_exec(r.owner,"update markets set status='OPEN' where id=$1::uuid",[pg.arg_text(r.market)]);
    schema_exec(r.owner,"insert into wallets(season_id,owner_kind,owner_id,asset_key) values "+
        "($1::uuid,'system','system:treasury','SEDI'),($1::uuid,'system','system:fees','SEDI'),"+
        "($1::uuid,'system','system:collateral:'||$2::text,'SEDI'),"+
        "($1::uuid,'system','system:shares:'||$2::text,'YES:'||$2::text),"+
        "($1::uuid,'system','system:shares:'||$2::text,'NO:'||$2::text)",
        [pg.arg_text(r.season),pg.arg_text(r.market)]);
}

fn runtime_request(r: SchemaRig,account: str,outcome: str,side: str,price: int,qty: int) -> service.AdmissionRequest {
    let intent=service.Intent { account_id:account,market_id:r.market,request_type:"limit",outcome:outcome,
        side:side,price:some(price),qty:some(qty),tif:none,spend:none };
    let prepared=service.prepare_admission(intent,service.Normalized {
        limit:price,qty:qty,tif:"GTC",estimated_principal:none,view_seq:none,protection_limit:none
    },"user","",schema_uuid(r),schema_uuid(r),schema_uuid(r),0);
    guard let request=prepared else let e=err_of(prepared) { panic(e); }
    return request;
}

fn runtime_admit(r: SchemaRig,request: service.AdmissionRequest) -> service.AdmissionReceipt {
    let admitted=service.admit_order(order_admission_store(new_postgres(r.app,10000000000)),request);
    guard let receipt=admitted else let e=err_of(admitted) { panic(e); }
    return receipt;
}

fn runtime_actor(r: SchemaRig) -> service.Actor[Postgres] {
    let postgres=new_postgres(r.app,10000000000);
    let restored=service.recover_book(recovery_store(postgres),r.market,4);
    guard let book=restored else let e=err_of(restored) { panic(e); }
    let workspace=core.new_workspace(&book,4);
    let created=service.new_actor(actor_writer(postgres),book,workspace,r.node,1);
    guard let actor=created else let e=err_of(created) { panic(e); }
    return actor;
}

fn runtime_drain(r: SchemaRig,actor: service.Actor[Postgres]) -> [service.Record] {
    let queue=service.new_queue(command_queue(new_postgres(r.app,10000000000)));
    let loaded=service.load_pending(queue,r.market,0,64);
    guard let batch=loaded else let e=err_of(loaded) { panic(e); }
    let records:[service.Record]=[];
    for command in batch.commands {
        let processed=service.process_one(actor,command);
        guard let record=processed else let e=err_of(processed) { panic(e); }
        push(records,record);
    }
    return records;
}

fn runtime_place(r: SchemaRig,actor: service.Actor[Postgres],account: str,outcome: str,side: str,price: int,qty: int) -> service.Record {
    let request=runtime_request(r,account,outcome,side,price,qty);
    let _admitted=runtime_admit(r,request);
    let records=runtime_drain(r,actor);
    assert(len(records)==1);
    return records[0];
}

fn test_runtime_posts_all_four_modes_and_recovers_nonzero_supply() {
    guard let r=schema_rig() else { return; }
    runtime_setup(r);
    let a=runtime_account(r,427); let b=runtime_account(r,427);
    let c=runtime_account(r,427); let d=runtime_account(r,427);
    let actor=runtime_actor(r);
    let rest=runtime_place(r,actor,a,"YES","BUY",40,3);
    assert(len(rest.fills)==0);
    let mint=runtime_place(r,actor,b,"NO","BUY",60,3);
    assert(len(mint.fills)==1 && mint.fills[0].mode=="MINT");
    let _ask=runtime_place(r,actor,a,"YES","SELL",45,2);
    let yes=runtime_place(r,actor,c,"YES","BUY",50,2);
    assert(len(yes.fills)==1 && yes.fills[0].mode=="TRANSFER_YES");
    let _bid=runtime_place(r,actor,b,"NO","SELL",60,1);
    let no=runtime_place(r,actor,d,"NO","BUY",65,1);
    assert(len(no.fills)==1 && no.fills[0].mode=="TRANSFER_NO");
    let _merge_bid=runtime_place(r,actor,b,"NO","SELL",60,1);
    let merge=runtime_place(r,actor,c,"YES","SELL",35,1);
    assert(len(merge.fills)==1 && merge.fills[0].mode=="MERGE");
    assert(actor.book.pairs==2);
    let recovered=service.recover_book(recovery_store(new_postgres(r.app,10000000000)),r.market,1);
    guard let book=recovered else let e=err_of(recovered) { panic(e); }
    assert(book.pairs==2 && book.last_seq==8);
    assert(core.snapshot(&book).state_hash==core.snapshot(&actor.book).state_hash);
    assert(schema_int(r.owner,"select sum(qty)::bigint as value from positions where market_id=$1::uuid and outcome='YES'",[pg.arg_text(r.market)])==2);
    assert(schema_int(r.owner,"select sum(qty)::bigint as value from positions where market_id=$1::uuid and outcome='NO'",[pg.arg_text(r.market)])==2);
    let lst=ledger_store.ledger_store(ledger_store.new_postgres(r.app,none,10000000000,50000000));
    let reconciled=lst.recon_run(lst.context,true);
    guard let found=reconciled else let e=err_of(reconciled) { panic(e); }
    guard let run=found else { panic("missing full reconciliation"); }
    assert(run.ok ?? false,inspect(run.checks));
    schema_close(r);
}

fn test_runtime_retries_keep_one_hold_and_cancellation_releases_it() {
    guard let r=schema_rig() else { return; }
    runtime_setup(r);
    let a=runtime_account(r,427);
    let request=runtime_request(r,a,"YES","BUY",40,3);
    let first=runtime_admit(r,request);
    request.order_id=schema_uuid(r); request.command_ref=schema_uuid(r); request.order.id=request.order_id;
    let retry=runtime_admit(r,request);
    assert(retry.existing && retry.order_id==first.order_id);
    assert(schema_int(r.owner,"select count(*)::bigint as value from holds",[])==1);
    let actor=runtime_actor(r);
    let _placed=runtime_drain(r,actor);
    let queue=service.new_queue(command_queue(new_postgres(r.app,10000000000)));
    let cancelled=service.enqueue_cancel_owned(queue,first.order_id,a,schema_uuid(r));
    guard let cancel=cancelled else let e=err_of(cancelled) { panic(e); }
    let records=runtime_drain(r,actor);
    assert(len(records)==1 && len(records[0].postings)==1);
    assert(schema_int(r.owner,"select count(*)::bigint as value from holds where status='open'",[])==0);
    assert(schema_int(r.owner,"select free_units as value from wallets where owner_id=$1 and asset_key='SEDI'",[pg.arg_text(a)])==427);
    let repeat=service.enqueue_cancel_owned(queue,first.order_id,a,schema_uuid(r));
    guard let repeated=repeat else let e=err_of(repeat) { panic(e); }
    assert(repeated.existing && repeated.command_ref==cancel.command_ref);
    schema_exec(r.owner,"update markets set status='CLOSED' where id=$1::uuid",[pg.arg_text(r.market)]);
    let closed_retry=runtime_admit(r,request);
    assert(closed_retry.existing && closed_retry.status=="CANCELLED");
    schema_close(r);
}

fn test_runtime_season_close_rejects_pending_and_releases_resting_holds() {
    guard let r=schema_rig() else { return; }
    runtime_setup(r);
    let a=runtime_account(r,427);
    let actor=runtime_actor(r);
    let _resting=runtime_place(r,actor,a,"YES","BUY",40,3);
    let _pending=runtime_admit(r,runtime_request(r,a,"YES","BUY",30,2));
    schema_exec(r.owner,"update seasons set status='CLOSING' where id=$1::uuid",[pg.arg_text(r.season)]);
    let queue=service.new_queue(command_queue(new_postgres(r.app,10000000000)));
    let synced=service.sync_lifecycle(queue,r.market);
    guard let pending=synced else let e=err_of(synced) { panic(e); }
    assert(pending==2);
    let records=runtime_drain(r,actor);
    assert(len(records)==2 && records[0].command_kind=="RejectPlace" && records[1].command_kind=="Close");
    assert(actor.book.mode=="CLOSED");
    assert(schema_int(r.owner,"select count(*)::bigint as value from holds where status='open'",[])==0);
    assert(schema_int(r.owner,"select count(*)::bigint as value from market_queue_claims where released_at is null",[])==0);
    let recovered=service.recover_book(recovery_store(new_postgres(r.app,10000000000)),r.market,1);
    guard let book=recovered else let e=err_of(recovered) { panic(e); }
    assert(book.mode=="CLOSED" && book.last_seq==3);
    schema_close(r);
}

fn runtime_attempt(r: SchemaRig,request: service.AdmissionRequest) -> str {
    let admitted=service.admit_order(order_admission_store(new_postgres(r.app,10000000000)),request);
    if let receipt=admitted { return receipt.order_id; }
    else let error=err_of(admitted) { return error; }
}

fn test_runtime_concurrent_identical_admissions_reserve_exactly_once() {
    guard let r=schema_rig() else { return; }
    runtime_setup(r);
    let a=runtime_account(r,427);
    let request=runtime_request(r,a,"YES","BUY",40,3);
    let workers:[join[str]]=[];
    for i in 0..20 { push(workers,spawn runtime_attempt(r,request)); }
    for worker in workers {
        let joined=join_wait(worker);
        guard let id=joined else let e=err_of(joined) { panic(e); }
        assert(id==request.order_id,id);
    }
    assert(schema_int(r.owner,"select count(*)::bigint as value from holds",[])==1);
    assert(schema_int(r.owner,"select count(*)::bigint as value from orders",[])==1);
    assert(schema_int(r.owner,"select count(*)::bigint as value from market_queue_claims where released_at is null",[])==1);
    schema_close(r);
}

fn test_runtime_takeover_verifies_new_epoch_before_draining_admitted_work() {
    guard let r=schema_rig() else { return; }
    runtime_setup(r);
    let a=runtime_account(r,427);
    let request=runtime_request(r,a,"YES","BUY",40,3);
    let _admitted=runtime_admit(r,request);
    let successor=schema_uuid(r);
    let ownership=service.new_ownership(ownership_store(new_postgres(r.app,10000000000)));
    let registered=service.register_node(ownership,successor,"successor",30);
    guard let _registered=registered else let e=err_of(registered) { panic(e); }
    let released=service.release(ownership,r.market,r.node,1);
    guard let _released=released else let e=err_of(released) { panic(e); }
    let claimed=service.acquire(ownership,r.market,successor,30);
    guard let claim=claimed else let e=err_of(claimed) { panic(e); }
    assert(claim.acquired && claim.epoch==2);
    let postgres=new_postgres(r.app,10000000000);
    let restored=service.recover_book(recovery_store(postgres),r.market,4);
    guard let book=restored else let e=err_of(restored) { panic(e); }
    let workspace=core.new_workspace(&book,4);
    let created=service.new_actor(actor_writer(postgres),book,workspace,successor,2);
    guard let actor=created else let e=err_of(created) { panic(e); }
    let captured=service.snapshot_write(actor);
    guard let checkpoint=captured else let e=err_of(captured) { panic(e); }
    let verified=st_verify_epoch(postgres,checkpoint,2,2);
    guard let book_seq=verified else let e=err_of(verified) { panic(e); }
    assert(book_seq==0);
    let records=runtime_drain(r,actor);
    assert(len(records)==1 && records[0].decision=="ACCEPTED");
    let ready=service.mark_ready(ownership,r.market,successor,2);
    guard let is_ready=ready else let e=err_of(ready) { panic(e); }
    assert(is_ready);
    schema_close(r);
}

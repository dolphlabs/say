import "../domain" as core;
import "json";

gc struct RecoveryFake { data: RecoveryData, calls: int, projection_valid: bool }

fn recovery_fake_load(f: RecoveryFake, _market_id: str) -> result[RecoveryData,str] {
    f.calls+=1;
    return ok(f.data);
}

fn recovery_fake_save(_f: RecoveryFake, _snapshot: SnapshotWrite) -> result[bool,str] {
    return ok(true);
}

fn recovery_fake_reconcile(f: RecoveryFake,_market_id: str,_snapshot: core.Snapshot) -> result[bool,str] {
    return ok(f.projection_valid);
}

fn recovery_fixture() -> RecoveryFake {
    let policy=core.Policy {
        market_id:"00000000-0000-4000-a000-000000000900",
        season_id:"00000000-0000-4000-a000-000000000901",
        V:100,min_price:1,max_price:99,tick:1,max_order_qty:1000,min_order_notional:2
    };
    let created=core.new_book(policy,4,0); guard let book=created else { panic("book"); }
    let workspace=core.new_workspace(&book,4);
    let command=core.Command {
        kind:"Snapshot",seq:1,ref:"00000000-0000-4000-a000-000000000902",
        order:core.empty_order(),order_id:"",account_id:"",system:true,reason:""
    };
    assert(core.plan(&book,command,&mut workspace)=="");
    let recorded=record(&book,&mut workspace); guard let transition=recorded else { panic("record"); }
    assert(core.apply(&mut book,&mut workspace)=="");
    let snapshot=core.snapshot(&book);
    return RecoveryFake {
        data:RecoveryData {
            policy:policy,pairs:0,committed_seq:1,rolling_hash:snapshot.state_hash,mode:book.mode,
            base_seq:0,snapshots:[],
            steps:[RecoveryStep { seq:1,command_payload:json.encode(command),transition_payload:json.encode(transition) }]
        },
        calls:0,projection_valid:true
    };
}

fn test_recovery_restores_verified_snapshot_and_replays_its_suffix() {
    let fake=recovery_fixture();
    let loaded=fake.data.steps[0];
    let decoded:result[Record,str]=json.decode(loaded.transition_payload);
    guard let transition=decoded else { panic("transition decode"); }
    let command_result:result[core.Command,str]=json.decode(loaded.command_payload);
    guard let command=command_result else { panic("command decode"); }
    let start=core.new_book(fake.data.policy,4,0);
    guard let book=start else { panic("start book"); }
    let workspace=core.new_workspace(&book,4);
    assert(core.plan(&book,command,&mut workspace)=="");
    let decided=record(&book,&mut workspace);
    guard let _record=decided else { panic("record"); }
    assert(core.apply(&mut book,&mut workspace)=="");
    let snapshot=core.snapshot(&book);
    let hash_workspace=core.new_workspace(&book,4);
    assert(core.full_hash(&book,false,&mut hash_workspace)=="");
    fake.data.base_seq=1;
    fake.data.snapshots=[RecoverySnapshot {
        committed_seq:1,state_hash:snapshot.state_hash,
        full_hash:core.digest_text(hash_workspace.hashes.data,64),schema_version:1,
        payload:json.encode(snapshot)
    }];
    let store=RecoveryStore[RecoveryFake] {
        context:fake,load:recovery_fake_load,save_snapshot:recovery_fake_save,
        reconcile_projection:recovery_fake_reconcile,verify_epoch:recovery_fake_verify,quarantine:recovery_fake_quarantine
    };
    let recovered=recover_book(store,fake.data.policy.market_id,4);
    guard let restored=recovered else { panic("snapshot recovery failed"); }
    assert(restored.last_seq==1 && core.snapshot(&restored).state_hash==fake.data.rolling_hash);
}

fn test_recovery_falls_back_to_an_older_valid_snapshot() {
    let fake=recovery_fixture();
    let genesis_result=core.new_book(fake.data.policy,4,0);
    guard let genesis=genesis_result else { panic("genesis book"); }
    let genesis_snapshot=core.snapshot(&genesis);
    let genesis_workspace=core.new_workspace(&genesis,4);
    assert(core.full_hash(&genesis,false,&mut genesis_workspace)=="");
    let loaded=fake.data.steps[0];
    let command_result:result[core.Command,str]=json.decode(loaded.command_payload);
    guard let command=command_result else { panic("command decode"); }
    let applied=core.new_book(fake.data.policy,4,0);
    guard let book=applied else { panic("snapshot book"); }
    let workspace=core.new_workspace(&book,4);
    assert(core.plan(&book,command,&mut workspace)=="");
    let transition_result=record(&book,&mut workspace);
    guard let transition=transition_result else { panic("record"); }
    assert(core.apply(&mut book,&mut workspace)=="");
    let current_snapshot=core.snapshot(&book);
    let current_workspace=core.new_workspace(&book,4);
    assert(core.full_hash(&book,false,&mut current_workspace)=="");
    fake.data.base_seq=0;
    fake.data.snapshots=[
        RecoverySnapshot {
            committed_seq:1,state_hash:current_snapshot.state_hash,
            full_hash:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            schema_version:1,payload:json.encode(current_snapshot)
        },
        RecoverySnapshot {
            committed_seq:0,state_hash:genesis_snapshot.state_hash,
            full_hash:core.digest_text(genesis_workspace.hashes.data,64),
            schema_version:1,payload:json.encode(genesis_snapshot)
        }
    ];
    let store=RecoveryStore[RecoveryFake] {
        context:fake,load:recovery_fake_load,save_snapshot:recovery_fake_save,
        reconcile_projection:recovery_fake_reconcile,verify_epoch:recovery_fake_verify,quarantine:recovery_fake_quarantine
    };
    let recovered=recover_book(store,fake.data.policy.market_id,4);
    guard let restored=recovered else { panic("older snapshot recovery failed"); }
    assert(restored.last_seq==1 && core.snapshot(&restored).state_hash==fake.data.rolling_hash);
}

fn test_recovery_replays_decided_transitions_and_verifies_final_state() {
    let fake=recovery_fixture();
    let store=RecoveryStore[RecoveryFake] {
        context:fake,load:recovery_fake_load,save_snapshot:recovery_fake_save,
        reconcile_projection:recovery_fake_reconcile,verify_epoch:recovery_fake_verify,quarantine:recovery_fake_quarantine
    };
    let recovered=recover_book(store,fake.data.policy.market_id,1);
    guard let book=recovered else { panic("recovery failed"); }
    assert(book.last_seq==1 && book.mode=="OPEN" && fake.calls==1);
    assert(core.snapshot(&book).state_hash==fake.data.rolling_hash);
}

fn test_recovery_rejects_missing_sequences_and_final_hash_mismatch() {
    let fake=recovery_fixture();
    fake.data.steps[0].seq=2;
    let store=RecoveryStore[RecoveryFake] {
        context:fake,load:recovery_fake_load,save_snapshot:recovery_fake_save,
        reconcile_projection:recovery_fake_reconcile,verify_epoch:recovery_fake_verify,quarantine:recovery_fake_quarantine
    };
    let gap=recover_book(store,fake.data.policy.market_id,4);
    if let _book=gap { panic("recovery accepted a sequence gap"); }
    else let error=err_of(gap) { assert(error=="RECOVERY_SEQUENCE_GAP"); }

    let next=recovery_fixture();
    next.data.rolling_hash="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    let next_store=RecoveryStore[RecoveryFake] {
        context:next,load:recovery_fake_load,save_snapshot:recovery_fake_save,
        reconcile_projection:recovery_fake_reconcile,verify_epoch:recovery_fake_verify,quarantine:recovery_fake_quarantine
    };
    let mismatch=recover_book(next_store,next.data.policy.market_id,4);
    if let _book=mismatch { panic("recovery accepted an incorrect rolling hash"); }
    else let error=err_of(mismatch) { assert(error=="RECOVERY_HASH_MISMATCH"); }

    let drift=recovery_fixture();
    drift.projection_valid=false;
    let drift_store=RecoveryStore[RecoveryFake] {
        context:drift,load:recovery_fake_load,save_snapshot:recovery_fake_save,
        reconcile_projection:recovery_fake_reconcile,verify_epoch:recovery_fake_verify,quarantine:recovery_fake_quarantine
    };
    let projection=recover_book(drift_store,drift.data.policy.market_id,4);
    if let _book=projection { panic("recovery accepted projection drift"); }
    else let error=err_of(projection) { assert(error=="RECOVERY_PROJECTION_MISMATCH"); }
}

fn recovery_fake_verify(_f: RecoveryFake,_s: SnapshotWrite,_p: int,_c: int) -> result[int,str] { return ok(0); }

fn recovery_fake_quarantine(_f: RecoveryFake,_market: str,_node: str,_epoch: int,_reason: str) -> result[bool,str] { return ok(true); }

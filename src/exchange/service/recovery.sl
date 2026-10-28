import "json";
import "../domain" as core;

pub fn recover_book[C](store: RecoveryStore[C], market_id: str, initial_capacity: int) -> result[core.Book, str] {
    let scratch=core.byte_writer(36);
    if !core.canonical_uuid(market_id,scratch.data) || initial_capacity<1 || initial_capacity>100000 {
        return err("INVALID_RECOVERY_REQUEST");
    }
    let load=store.load;
    let loaded=load(store.context,market_id);
    guard let data=loaded else let e=err_of(loaded) { return err(e); }
    if data.policy.market_id!=market_id || data.committed_seq<0 || data.pairs<0 ||
       len(data.rolling_hash)!=64 || data.base_seq<0 || data.base_seq>data.committed_seq ||
       (data.mode!="OPEN" && data.mode!="SUSPENDED" && data.mode!="CLOSED") {
        return err("RECOVERY_STATE_MISMATCH");
    }
    let base:result[core.Book,str]=err("RECOVERY_NO_VALID_SNAPSHOT");
    let restored_snapshot=false;
    for candidate in data.snapshots {
        if candidate.committed_seq<data.base_seq || candidate.committed_seq>data.committed_seq { continue; }
        let restored=restore_candidate(data.policy,candidate,data.steps,initial_capacity);
        if let book=restored {
            base=ok(book);
            restored_snapshot=true;
            break;
        }
    }
    if !restored_snapshot {
        if data.committed_seq>100000 { return err("RECOVERY_SNAPSHOT_REQUIRED"); }
        if data.base_seq!=0 { return err("RECOVERY_NO_VALID_SNAPSHOT"); }
        let created=core.new_book(data.policy,initial_capacity,0);
        guard let book=created else let e=err_of(created) { return err("RECOVERY_BOOK:"+e); }
        base=ok(book);
    }
    guard let book=base else let e=err_of(base) { return err(e); }
    let replay_from=book.last_seq+1;
    let replayed=replay_steps(book,data.steps,replay_from,data.committed_seq);
    guard let recovered=replayed else let e=err_of(replayed) { return err(e); }
    let final_snapshot=core.snapshot(&recovered);
    if recovered.last_seq!=data.committed_seq || final_snapshot.state_hash!=data.rolling_hash ||
       recovered.mode!=data.mode || recovered.pairs!=data.pairs {
        return err("RECOVERY_HASH_MISMATCH");
    }
    let reconcile=store.reconcile_projection;
    let reconciled=reconcile(store.context,market_id,final_snapshot);
    guard let projection_ok=reconciled else let e=err_of(reconciled) {
        return err("RECOVERY_PROJECTION_CHECK:"+e);
    }
    if !projection_ok { return err("RECOVERY_PROJECTION_MISMATCH"); }
    return ok(recovered);
}

fn restore_candidate(policy: core.Policy,candidate: RecoverySnapshot,steps: [RecoveryStep],initial_capacity: int) -> result[core.Book,str] {
    if candidate.schema_version!=1 || candidate.committed_seq<0 ||
       len(candidate.state_hash)!=64 || len(candidate.full_hash)!=64 {
        return err("RECOVERY_SNAPSHOT_METADATA");
    }
    let decoded:result[core.Snapshot,str]=json.decode(candidate.payload);
    guard let snapshot=decoded else let e=err_of(decoded) { return err("RECOVERY_SNAPSHOT_DECODE:"+e); }
    if snapshot.last_seq!=candidate.committed_seq || snapshot.state_hash!=candidate.state_hash ||
       !same_policy(snapshot.policy,policy) {
        return err("RECOVERY_SNAPSHOT_IDENTITY");
    }
    if candidate.committed_seq>0 {
        let has_anchor=false;
        for step in steps {
            if step.seq==candidate.committed_seq {
                let record_result:result[Record,str]=json.decode(step.transition_payload);
                guard let transition=record_result else let e=err_of(record_result) { return err("RECOVERY_SNAPSHOT_ANCHOR:"+e); }
                if transition.seq!=candidate.committed_seq || transition.state_hash!=candidate.state_hash {
                    return err("RECOVERY_SNAPSHOT_HASH");
                }
                has_anchor=true;
                break;
            }
        }
        if !has_anchor { return err("RECOVERY_SNAPSHOT_ANCHOR_MISSING"); }
    }
    let capacity=initial_capacity;
    if len(snapshot.orders)>capacity { capacity=len(snapshot.orders); }
    if capacity>100000 { return err("RECOVERY_CAPACITY_EXCEEDED"); }
    let restored=core.restore(snapshot,capacity);
    guard let book=restored else let e=err_of(restored) { return err("RECOVERY_SNAPSHOT_RESTORE:"+e); }
    let workspace=core.new_workspace(&book,capacity);
    let full_error=core.full_hash(&book,false,&mut workspace);
    if full_error!="" { return err("RECOVERY_SNAPSHOT_HASH:"+full_error); }
    if core.digest_text(workspace.hashes.data,64)!=candidate.full_hash {
        return err("RECOVERY_SNAPSHOT_FULL_HASH");
    }
    return ok(book);
}

fn same_policy(a: core.Policy,b: core.Policy) -> bool {
    return a.market_id==b.market_id && a.season_id==b.season_id && a.V==b.V &&
        a.min_price==b.min_price && a.max_price==b.max_price && a.tick==b.tick &&
        a.max_order_qty==b.max_order_qty && a.min_order_notional==b.min_order_notional;
}

fn replay_steps(book: core.Book,steps: [RecoveryStep],from_seq: int,committed_seq: int) -> result[core.Book,str] {
    let expected_seq=from_seq;
    let capacity=len(book.slots);
    let workspace=core.new_workspace(&book,capacity);
    for step in steps {
        if step.seq<from_seq || step.seq>committed_seq { continue; }
        if step.seq!=expected_seq { return err("RECOVERY_SEQUENCE_GAP"); }
        let decoded_command: result[core.Command,str]=json.decode(step.command_payload);
        guard let command=decoded_command else let e=err_of(decoded_command) {
            return err("RECOVERY_COMMAND_DECODE:"+e);
        }
        let decoded_record: result[Record,str]=json.decode(step.transition_payload);
        guard let transition=decoded_record else let e=err_of(decoded_record) {
            return err("RECOVERY_TRANSITION_DECODE:"+e);
        }
        if command.seq!=step.seq || transition.seq!=step.seq ||
           command.ref!=transition.command_ref || command.kind!=transition.command_kind {
            return err("RECOVERY_TRANSITION_IDENTITY");
        }
        let planned=core.plan(&book,command,&mut workspace);
        while planned=="NEED_CAPACITY" && len(book.slots)<100000 {
            let next=len(book.slots)*2;
            if next>100000 { next=100000; }
            let grown=core.grow(&book,next);
            guard let expanded=grown else let e=err_of(grown) { return err("RECOVERY_GROW:"+e); }
            book=expanded;
            workspace=core.new_workspace(&book,next);
            planned=core.plan(&book,command,&mut workspace);
        }
        if planned!="" { return err("RECOVERY_INPUT_PLAN:"+planned); }
        let materialized=record(&book,&mut workspace);
        guard let actual=materialized else let e=err_of(materialized) {
            return err("RECOVERY_INPUT_RECORD:"+e);
        }
        if !same_record(transition,actual) { return err("RECOVERY_INPUT_MISMATCH"); }
        let replay=prepare_replay(&book,transition,&mut workspace);
        while replay=="NEED_CAPACITY" {
            if len(book.slots)>=100000 { return err("RECOVERY_CAPACITY_EXCEEDED"); }
            let next=len(book.slots)*2;
            if next>100000 { next=100000; }
            let grown=core.grow(&book,next);
            guard let expanded=grown else let e=err_of(grown) { return err("RECOVERY_GROW:"+e); }
            book=expanded;
            workspace=core.new_workspace(&book,next);
            replay=prepare_replay(&book,transition,&mut workspace);
        }
        if replay!="" { return err("RECOVERY_REPLAY:"+replay); }
        let applied=core.apply(&mut book,&mut workspace);
        if applied!="" { return err("RECOVERY_APPLY:"+applied); }
        expected_seq+=1;
        if expected_seq>committed_seq { break; }
    }
    if expected_seq!=committed_seq+1 { return err("RECOVERY_SEQUENCE_GAP"); }
    return ok(book);
}

import "../domain" as core;

gc struct ActorFake {
    commit_ok: bool,
    eligibility_once: bool,
    commits: int,
    last_seq: int,
    last_epoch: int,
    last_node: str,
    last_kind: str
}

fn actor_commit(f: ActorFake, transition: Record, command: core.Command, node: str, epoch: int) -> result[bool, str] {
    f.commits += 1;
    f.last_seq = transition.seq;
    f.last_node = node;
    f.last_epoch = epoch;
    f.last_kind = command.kind;
    if f.eligibility_once && command.kind == "Place" {
        f.eligibility_once = false;
        return err("SAY_ELIGIBILITY:TRADING_HALTED");
    }
    return ok(f.commit_ok);
}

fn actor_fixture(commit_ok: bool, eligibility_once: bool) -> Actor[ActorFake] {
    let policy = core.Policy {
        market_id: "00000000-0000-4000-a000-000000000001",
        season_id: "00000000-0000-4000-a000-000000000002",
        V: 100,
        min_price: 1,
        max_price: 99,
        tick: 1,
        max_order_qty: 10000,
        min_order_notional: 2
    };
    let created = core.new_book(policy, 8, 0);
    guard let book = created else { panic("actor book"); }
    let workspace = core.new_workspace(&book, 8);
    let writer = ActorWriter[ActorFake] {
        context: ActorFake { commit_ok: commit_ok, eligibility_once: eligibility_once, commits: 0, last_seq: 0, last_epoch: 0, last_node: "", last_kind: "" },
        commit: actor_commit
    };
    let actor_result = new_actor(writer, book, workspace, "00000000-0000-4000-a000-000000000003", 4);
    guard let actor = actor_result else { panic("actor construction"); }
    return actor;
}

fn queued_snapshot() -> QueuedCommand {
    let command = core.Command {
        kind: "Snapshot",
        seq: 0,
        ref: "00000000-0000-4000-a000-000000000004",
        order: core.empty_order(),
        order_id: "",
        account_id: "",
        system: true,
        reason: ""
    };
    return QueuedCommand {
        command_ref: command.ref,
        command_id: 1,
        command_type: command.kind,
        order_id: "",
        source_key: "snapshot:actor-test",
        queue_bucket: 16,
        payload: json.encode(command)
    };
}

fn test_actor_commits_decision_before_applying_it() {
    let actor = actor_fixture(true,false);
    let processed = process_one(actor, queued_snapshot());
    guard let transition = processed else { panic("actor command failed"); }
    assert(transition.seq == 1 && actor.book.last_seq == 1);
    assert(actor.store.context.commits == 1);
    assert(actor.store.context.last_seq == 1);
    assert(actor.store.context.last_epoch == 4);
    assert(actor.store.context.last_node == "00000000-0000-4000-a000-000000000003");
}

fn test_actor_snapshot_captures_applied_state_and_checksum() {
    let actor=actor_fixture(true,false);
    let captured=snapshot_write(actor);
    guard let snapshot=captured else { panic("snapshot capture failed"); }
    let decoded:result[core.Snapshot,str]=json.decode(snapshot.payload);
    guard let payload=decoded else { panic("snapshot payload invalid"); }
    let workspace=core.new_workspace(&actor.book,8);
    assert(core.full_hash(&actor.book,false,&mut workspace)=="");
    assert(snapshot.committed_seq==0 && snapshot.state_hash==payload.state_hash);
    assert(snapshot.full_hash==core.digest_text(workspace.hashes.data,64));
    assert(snapshot.owner_epoch==4 && snapshot.node_id==actor.node_id);
    assert(actor.book.last_seq==0);
}

fn test_actor_does_not_apply_an_unconfirmed_commit() {
    let actor = actor_fixture(false,false);
    let processed = process_one(actor, queued_snapshot());
    if let _transition = processed { panic("unconfirmed commit applied"); }
    else let e = err_of(processed) { assert(e == "COMMIT_NOT_CONFIRMED"); }
    assert(actor.book.last_seq == 0 && actor.store.context.commits == 1);
}

fn test_actor_rejects_mismatched_durable_command_identity() {
    let actor = actor_fixture(true,false);
    let queued = queued_snapshot();
    queued.command_type = "Close";
    let processed = process_one(actor, queued);
    if let _transition = processed { panic("mismatched command accepted"); }
    else let e = err_of(processed) { assert(e == "INVALID_COMMAND_IDENTITY"); }
    assert(actor.book.last_seq == 0 && actor.store.context.commits == 0);
}

fn test_actor_converts_authoritative_place_rejection_to_durable_cleanup() {
    let actor=actor_fixture(true,true);
    let order=core.Order {
        id:"00000000-0000-4000-a000-000000000005",
        account_id:"00000000-0000-4000-a000-000000000006",
        owner_kind:"user",owner_group:"",outcome:"YES",side:"BUY",limit:10,qty:1,remaining:1,tif:"GTC",
        accepted_seq:0,fee_paid:false,sedi_hold_id:"00000000-0000-4000-a000-000000000007",share_hold_id:"",
        sedi_original:11,sedi_consumed:0,sedi_released:0,shares_original:0,shares_consumed:0,shares_released:0,
        filled:0,cancelled:0
    };
    let command=core.Command {
        kind:"Place",seq:0,ref:"00000000-0000-4000-a000-000000000008",order:order,
        order_id:"",account_id:order.account_id,system:false,reason:""
    };
    let queued=QueuedCommand {
        command_ref:command.ref,command_id:2,command_type:"Place",order_id:order.id,
        source_key:"place:actor-reject",queue_bucket:0,payload:json.encode(command)
    };
    let processed=process_one(actor,queued);
    guard let transition=processed else { panic("authoritative rejection was not persisted"); }
    assert(transition.command_kind=="RejectPlace" && transition.decision=="TRADING_HALTED");
    assert(actor.book.last_seq==1 && actor.store.context.commits==2);
    assert(actor.store.context.last_kind=="RejectPlace");
}

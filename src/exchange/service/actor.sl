import "json";
import "../domain" as core;
import "strings";

pub gc struct Actor[C] {
    store: ActorWriter[C],
    book: core.Book,
    workspace: core.Workspace,
    node_id: str,
    epoch: int
}

pub fn workspace_for(book: &core.Book, capacity: int) -> core.Workspace {
    let workspace_capacity=capacity;
    if len(book.slots)>workspace_capacity { workspace_capacity=len(book.slots); }
    return core.new_workspace(book,workspace_capacity);
}

pub fn snapshot_write[C](actor: Actor[C]) -> result[SnapshotWrite,str] {
    let full_error=core.full_hash(&actor.book,false,&mut actor.workspace);
    if full_error!="" { return err(full_error); }
    let snapshot=core.snapshot(&actor.book);
    return ok(SnapshotWrite {
        market_id:actor.book.policy.market_id,node_id:actor.node_id,committed_seq:actor.book.last_seq,
        state_hash:snapshot.state_hash,full_hash:core.digest_text(actor.workspace.hashes.data,64),
        payload:json.encode(snapshot),owner_epoch:actor.epoch
    });
}

pub fn new_actor[C](store: ActorWriter[C], book: core.Book, workspace: core.Workspace, node_id: str, epoch: int) -> result[Actor[C], str] {
    if !valid_uuid(node_id) || epoch < 1 || book.last_seq < 0 {
        return err("INVALID_ACTOR");
    }
    return ok(Actor[C] { store: store, book: book, workspace: workspace, node_id: node_id, epoch: epoch });
}

pub fn process_one[C](actor: Actor[C], queued: QueuedCommand) -> result[Record, str] {
    if queued.command_id < 1 || !valid_uuid(queued.command_ref) {
        return err("INVALID_COMMAND_WINDOW");
    }
    let decoded: result[core.Command, str] = json.decode(queued.payload);
    guard let command = decoded else let e = err_of(decoded) { return err("INVALID_COMMAND_PAYLOAD: " + e); }
    if command.kind != queued.command_type || command.ref != queued.command_ref {
        return err("INVALID_COMMAND_IDENTITY");
    }
    if queued.command_type == "Place" {
        if command.order.id != queued.order_id { return err("INVALID_COMMAND_IDENTITY"); }
    } else if queued.command_type == "Cancel" {
        if command.order_id != queued.order_id { return err("INVALID_COMMAND_IDENTITY"); }
    } else if queued.order_id != "" || command.order_id != "" {
        return err("INVALID_COMMAND_IDENTITY");
    }
    command.seq = actor.book.last_seq + 1;
    if command.kind == "Place" || command.kind == "RejectPlace" {
        command.order.accepted_seq = command.seq;
    }
    let planned = core.plan(&actor.book, command, &mut actor.workspace);
    while planned=="NEED_CAPACITY" && len(actor.book.slots)<100000 {
        let capacity=len(actor.book.slots)*2;
        if capacity>100000 { capacity=100000; }
        let grown=core.grow(&actor.book,capacity);
        guard let book=grown else let e=err_of(grown) { return err("GROW_"+e); }
        actor.book=book;
        actor.workspace=core.new_workspace(&actor.book,capacity);
        planned=core.plan(&actor.book,command,&mut actor.workspace);
    }
    if planned != "" { return err("PLAN_" + planned); }
    let materialized = record(&actor.book, &mut actor.workspace);
    guard let transition = materialized else let e = err_of(materialized) { return err("RECORD_" + e); }
    if transition.command_ref != queued.command_ref || transition.seq != command.seq {
        return err("TRANSITION_IDENTITY_MISMATCH");
    }
    let commit = actor.store.commit(actor.store.context, transition, command, actor.node_id, actor.epoch);
    if let _confirmed = commit {
    } else let e = err_of(commit) {
        let rejection = eligibility_rejection(e);
        if rejection == "" { return err("COMMIT_UNCONFIRMED: " + e); }
        command.kind = "RejectPlace";
        command.reason = rejection;
        let rejected_plan = core.plan(&actor.book, command, &mut actor.workspace);
        if rejected_plan != "" { return err("REJECTION_PLAN_" + rejected_plan); }
        let rejected_record = record(&actor.book, &mut actor.workspace);
        guard let rejected_transition = rejected_record else let record_error = err_of(rejected_record) {
            return err("REJECTION_RECORD_" + record_error);
        }
        let rejected_commit = actor.store.commit(actor.store.context, rejected_transition, command, actor.node_id, actor.epoch);
        guard let _rejected = rejected_commit else let commit_error = err_of(rejected_commit) {
            return err("REJECTION_COMMIT_UNCONFIRMED: " + commit_error);
        }
        if !_rejected { return err("REJECTION_COMMIT_NOT_CONFIRMED"); }
        let applied_rejection = core.apply(&mut actor.book, &mut actor.workspace);
        if applied_rejection != "" { return err("APPLY_AFTER_REJECTION_COMMIT_" + applied_rejection); }
        return ok(rejected_transition);
    }
    guard let committed = commit else { return err("COMMIT_UNCONFIRMED"); }
    if !committed { return err("COMMIT_NOT_CONFIRMED"); }
    let applied = core.apply(&mut actor.book, &mut actor.workspace);
    if applied != "" { return err("APPLY_AFTER_COMMIT_" + applied); }
    return ok(transition);
}

fn eligibility_rejection(error: str) -> str {
    if strings.contains(error,"SAY_ELIGIBILITY:MARKET_NOT_OPEN") { return "MARKET_NOT_OPEN"; }
    if strings.contains(error,"SAY_ELIGIBILITY:MARKET_SUSPENDED") { return "MARKET_SUSPENDED"; }
    if strings.contains(error,"SAY_ELIGIBILITY:MARKET_CLOSED") { return "MARKET_CLOSED"; }
    if strings.contains(error,"SAY_ELIGIBILITY:TRADING_HALTED") { return "TRADING_HALTED"; }
    if strings.contains(error,"SAY_ELIGIBILITY:SEASON_NOT_ACTIVE") { return "SEASON_NOT_ACTIVE"; }
    if strings.contains(error,"SAY_ELIGIBILITY:MARKET_DEGRADED") { return "MARKET_DEGRADED"; }
    if strings.contains(error,"SAY_ELIGIBILITY:ACCOUNT_DISABLED") { return "ACCOUNT_DISABLED"; }
    return "";
}

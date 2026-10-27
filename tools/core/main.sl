import "io";
import "json";
import "../../src/exchange/domain" as core;
import "../../src/exchange/service" as exchange;

gc struct InputCommand {
    kind: str, seq: int, ref: str, order: opt[core.Order], order_id: opt[str], account_id: opt[str], system: opt[bool], reason: opt[str],
}
gc struct Input {
    op: str, policy: opt[core.Policy], pairs: opt[int], capacity: opt[int], command: opt[InputCommand], snapshot: opt[core.Snapshot],
    transitions: opt[[exchange.Record]], expected_state_hash: opt[str], expected_full_hash: opt[str],
}
gc struct Output { snapshot: core.Snapshot, full_hash: str, transition: opt[exchange.Record] }
gc struct Failure { error: str }
gc struct Checked { checked: int, seq: int, state_hash: str, full_hash: str }

fn failure(error: str) { println(json.encode(Failure { error: error })); }

fn read_input() -> opt[Input] {
    while true {
        let read = io.read_line(); guard let maybe = read else let e = err_of(read) { failure(e); return none; }
        guard let line = maybe else { return none; }
        let parsed: result[Input, str] = json.decode(line);
        if let request = parsed { return some(request); }
        else let error = err_of(parsed) { failure(error); }
    }
    return none;
}

fn create(request: Input) -> result[core.Book, str] {
    let capacity = request.capacity ?? 1024;
    if request.op == "restore" || request.op == "replay" {
        guard let s = request.snapshot else { return err("SNAPSHOT_REQUIRED"); }
        return core.restore(s, capacity);
    }
    guard let p = request.policy else { return err("POLICY_REQUIRED"); }
    return core.new_book(p, capacity, request.pairs ?? 0);
}

fn output(b: &core.Book, w: &mut core.Workspace, transition: opt[exchange.Record]) {
    let error = core.full_hash(b, false, &mut *w);
    if error != "" { failure(error); return; }
    println(json.encode(Output { snapshot: core.snapshot(b), full_hash: core.digest_text(w.hashes.data, 64), transition: transition }));
}

fn replay(b: &mut core.Book, w: &mut core.Workspace, request: Input) -> str {
    guard let records = request.transitions else { return "TRANSITIONS_REQUIRED"; }
    for r in records {
        let prepared = exchange.prepare_replay(&*b, r, &mut *w);
        if prepared != "" { return prepared; }
        let applied = core.apply(&mut *b, &mut *w);
        if applied != "" { return applied; }
    }
    return "";
}

let next = read_input();
while true {
    guard let initial = next else { break; }
    if initial.op != "init" && initial.op != "restore" && initial.op != "replay" {
        failure("NOT_INITIALIZED"); next = read_input(); continue;
    }
    let created = create(initial);
    guard let book = created else let error = err_of(created) { failure(error); next = read_input(); continue; }
    let workspace = core.new_workspace(&book, initial.capacity ?? 1024);
    let checks = 0;
    if initial.op == "replay" {
        let error = replay(&mut book, &mut workspace, initial);
        if error != "" { failure(error); next = read_input(); continue; }
    }
    output(&book, &mut workspace, none);
    let pending: opt[exchange.Record] = none;
    while true {
        next = read_input(); guard let request = next else { break; }
        if request.op == "init" || request.op == "restore" || request.op == "replay" { break; }
        if request.op == "step" || request.op == "plan" || request.op == "check" {
            guard let incoming = request.command else { failure("COMMAND_REQUIRED"); continue; }
            let cmd = core.Command { kind: incoming.kind, seq: incoming.seq, ref: incoming.ref, order: incoming.order ?? core.empty_order(),
                order_id: incoming.order_id ?? "", account_id: incoming.account_id ?? "", system: incoming.system ?? false, reason: incoming.reason ?? "USER_CANCEL" };
            pending = none;
            let error = core.plan(&book, cmd, &mut workspace);
            if error != "" { failure(error); continue; }
            if request.op == "check" {
                guard let expected = request.expected_state_hash else { failure("EXPECTED_HASH_REQUIRED"); continue; }
                if core.digest_text(workspace.hashes.data, 32) != expected { failure("STATE_HASH_MISMATCH_AT_" + to_str(cmd.seq)); continue; }
                if let full = request.expected_full_hash {
                    let hash_error = core.full_hash(&book, true, &mut workspace);
                    if hash_error != "" { failure(hash_error); continue; }
                    if core.digest_text(workspace.hashes.data, 64) != full { failure("FULL_HASH_MISMATCH_AT_" + to_str(cmd.seq)); continue; }
                }
                let applied = core.apply(&mut book, &mut workspace);
                if applied != "" { failure(applied); continue; }
                let invariant = core.verify(&book, &mut workspace);
                if invariant != "" { failure(invariant); continue; }
                checks += 1;
                continue;
            }
            let converted = exchange.record(&book, &mut workspace);
            guard let r = converted else let error = err_of(converted) { failure(error); continue; }
            pending = some(r);
            if request.op == "step" {
                let applied = core.apply(&mut book, &mut workspace);
                if applied != "" { failure(applied); continue; }
            }
            output(&book, &mut workspace, pending);
        } else if request.op == "apply" {
            let error = core.apply(&mut book, &mut workspace);
            if error != "" { failure(error); continue; }
            output(&book, &mut workspace, none);
        } else if request.op == "discard" {
            workspace.ready = false; pending = none;
            output(&book, &mut workspace, none);
        } else if request.op == "snapshot" || request.op == "verify" {
            let error = core.verify(&book, &mut workspace);
            if error != "" { failure(error); continue; }
            output(&book, &mut workspace, none);
        } else if request.op == "checked" {
            let error = core.full_hash(&book, false, &mut workspace);
            if error != "" { failure(error); continue; }
            println(json.encode(Checked { checked: checks, seq: book.last_seq, state_hash: core.digest_text(book.digest.data, 0), full_hash: core.digest_text(workspace.hashes.data, 64) }));
        } else { failure("INVALID_OPERATION"); }
    }
}

gc struct FakeQueue {
    batch: CommandBatch,
    enqueue_result: EnqueueResult,
    calls: int
}

fn fake_enqueue(f: FakeQueue, _command: EnqueueCommand) -> result[EnqueueResult, str] {
    f.calls += 1;
    return ok(f.enqueue_result);
}

fn fake_cancel(f: FakeQueue, _market_id: str, _order_id: str, _account_id: str,
               command_ref: str, _source_key: str, _payload: str) -> result[EnqueueResult, str] {
    f.calls += 1;
    let response=f.enqueue_result;
    response.command_ref=command_ref;
    return ok(response);
}

fn fake_cancel_owned(f: FakeQueue, _order_id: str, _account_id: str,
                     command_ref: str) -> result[EnqueueResult,str] {
    f.calls+=1;
    let response=f.enqueue_result;
    response.command_ref=command_ref;
    return ok(response);
}

fn fake_load(f: FakeQueue, _market_id: str, _after: int, _limit: int) -> result[CommandBatch, str] {
    f.calls += 1;
    return ok(f.batch);
}

fn fake_queue(f: FakeQueue) -> Queue[FakeQueue] {
    return new_queue(CommandQueue[FakeQueue] {
        context: f, enqueue_control: fake_enqueue, enqueue_cancel: fake_cancel,
        enqueue_cancel_owned:fake_cancel_owned,load_pending: fake_load,sync_lifecycle:fake_sync_lifecycle
    });
}

fn test_owned_cancel_port_keeps_account_scope_and_validates_ids() {
    let queue=fake_queue(FakeQueue {
        batch:CommandBatch { frontier:0,commands:[] },
        enqueue_result:EnqueueResult { command_ref:"",queue_bucket:16,existing:false },calls:0
    });
    let ref="00000000-0000-4000-a000-000000000003";
    let cancel_result=enqueue_cancel_owned(queue,"00000000-0000-4000-a000-000000000002",
        "00000000-0000-4000-a000-000000000004",ref);
    guard let receipt=cancel_result else { panic("owned cancel failed"); }
    assert(receipt.command_ref==ref && queue.store.context.calls==1);
    let invalid=enqueue_cancel_owned(queue,"bad","00000000-0000-4000-a000-000000000004",ref);
    if let _receipt=invalid { panic("invalid owned cancel accepted"); }
    else let error=err_of(invalid) { assert(error=="INVALID_CANCEL"); }
    assert(queue.store.context.calls==1);
}

fn test_pending_loader_returns_frontier_and_commands() {
    let command = QueuedCommand {
        command_ref: "00000000-0000-4000-a000-000000000003",
        command_id: 8,
        command_type: "Place",
        order_id: "00000000-0000-4000-a000-000000000004",
        source_key: "order:8",
        queue_bucket: 3,
        payload: "{\"qty\":2}"
    };
    let queue = fake_queue(FakeQueue {
        batch: CommandBatch { frontier: 10, commands: [command] },
        enqueue_result: EnqueueResult { command_ref: "", queue_bucket: 0, existing: false },
        calls: 0
    });
    let loaded = load_pending(queue, "00000000-0000-4000-a000-000000000001", 7, 64);
    guard let batch = loaded else { panic("valid command window rejected"); }
    assert(batch.frontier == 10 && len(batch.commands) == 1);
    assert(batch.commands[0].command_id == 8 && batch.commands[0].payload == "{\"qty\":2}");
}

fn test_cancel_enqueue_validates_identity_and_builds_command() {
    let queue=fake_queue(FakeQueue {
        batch:CommandBatch { frontier:0,commands:[] },
        enqueue_result:EnqueueResult { command_ref:"",queue_bucket:16,existing:false },calls:0
    });
    let ref="00000000-0000-4000-a000-000000000003";
    let enqueued=enqueue_cancel(queue,"00000000-0000-4000-a000-000000000001",
        "00000000-0000-4000-a000-000000000002","00000000-0000-4000-a000-000000000004",
        ref,"cancel:request");
    guard let receipt=enqueued else { panic("valid cancellation rejected"); }
    assert(receipt.command_ref==ref && receipt.queue_bucket==16 && queue.store.context.calls==1);
    let invalid=enqueue_cancel(queue,"bad","00000000-0000-4000-a000-000000000002",
        "00000000-0000-4000-a000-000000000004",ref,"cancel:request");
    if let _result=invalid { panic("invalid cancellation accepted"); }
    else let e=err_of(invalid) { assert(e=="INVALID_CANCEL"); }
    assert(queue.store.context.calls==1);
}

fn test_pending_loader_rejects_invalid_windows_before_store_access() {
    let queue = fake_queue(FakeQueue {
        batch: CommandBatch { frontier: 0, commands: [] },
        enqueue_result: EnqueueResult { command_ref: "", queue_bucket: 0, existing: false },
        calls: 0
    });
    let bad_market = load_pending(queue, "invalid", 0, 1);
    if let _batch = bad_market { panic("invalid market accepted"); }
    else let e = err_of(bad_market) { assert(e == "INVALID_COMMAND_WINDOW"); }
    let bad_limit = load_pending(queue, "00000000-0000-4000-a000-000000000001", 0, 65);
    if let _batch = bad_limit { panic("oversized command batch accepted"); }
    else let e = err_of(bad_limit) { assert(e == "INVALID_COMMAND_WINDOW"); }
}

fn test_control_enqueue_rejects_order_commands_and_identity() {
    let queue = fake_queue(FakeQueue {
        batch: CommandBatch { frontier: 0, commands: [] },
        enqueue_result: EnqueueResult {
            command_ref: "00000000-0000-4000-a000-000000000003",
            queue_bucket: 2,
            existing: false
        },
        calls: 0
    });
    let valid = EnqueueCommand {
        market_id: "00000000-0000-4000-a000-000000000001",
        command_ref: "00000000-0000-4000-a000-000000000003",
        command_type: "Snapshot",
        order_id: "",
        source_key: "snapshot:fixture",
        payload: "{}",
        bucket_start: 2
    };
    let queued = enqueue_control(queue, valid);
    guard let queued_value = queued else { panic("valid command rejected"); }
    assert(!queued_value.existing && queued_value.queue_bucket == 2);

    let invalid = EnqueueCommand {
        market_id: valid.market_id,
        command_ref: valid.command_ref,
        command_type: "Place",
        order_id: "00000000-0000-4000-a000-000000000004",
        source_key: valid.source_key,
        payload: valid.payload,
        bucket_start: 2
    };
    let rejected = enqueue_control(queue, invalid);
    if let _result = rejected { panic("control queue accepted a Place command"); }
    else let e = err_of(rejected) { assert(e == "INVALID_COMMAND"); }
}

fn fake_sync_lifecycle(f: FakeQueue,_market: str) -> result[int,str] { return ok(len(f.batch.commands)); }

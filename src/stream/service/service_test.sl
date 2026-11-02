import "../domain" as domain;

gc struct FakeStoreCtx {
    book_view_calls: int
}

fn fake_read_market_stream(ctx: FakeStoreCtx, mid: str, lid: str, count: int, blk: int) -> result[[StreamMessage], str] {
    let empty: [StreamMessage] = [];
    return ok(empty);
}

fn fake_read_shard_stream(ctx: FakeStoreCtx, shard: int, lid: str, count: int, blk: int) -> result[[StreamMessage], str] {
    let empty: [StreamMessage] = [];
    return ok(empty);
}

fn fake_read_session_revocations(ctx: FakeStoreCtx, lid: str, count: int, blk: int) -> result[[SessionRevocation], str] {
    let empty: [SessionRevocation] = [];
    return ok(empty);
}

fn fake_get_book_view(ctx: FakeStoreCtx, mid: str) -> result[opt[RuntimeBookSnapshot], str] {
    ctx.book_view_calls += 1;
    let b1 = domain.Level { side: "bid", yes_price: 45, qty: 10 };
    let a1 = domain.Level { side: "ask", yes_price: 55, qty: 15 };
    let snap = RuntimeBookSnapshot {
        market_id: mid,
        owner_epoch: 1,
        committed_seq: 100,
        book_seq: 100,
        value: 100,
        min_price: 1,
        max_price: 99,
        tick: 1,
        health: "READY",
        mode: "OPEN",
        bids: [b1],
        asks: [a1]
    };
    return ok(some(snap));
}

fn fake_get_market_stats(ctx: FakeStoreCtx) -> result[[CardStatItem], str] {
    let empty: [CardStatItem] = [];
    return ok(empty);
}

fn fake_is_session_valid(ctx: FakeStoreCtx, sid: str) -> result[bool, str] {
    return ok(true);
}

fn make_fake_store() -> StreamStore[FakeStoreCtx] {
    let ctx = FakeStoreCtx { book_view_calls: 0 };
    return StreamStore[FakeStoreCtx] {
        context: ctx,
        read_market_stream: fake_read_market_stream,
        read_shard_stream: fake_read_shard_stream,
        read_session_revocations: fake_read_session_revocations,
        get_book_view: fake_get_book_view,
        get_market_stats: fake_get_market_stats,
        is_session_valid: fake_is_session_valid
    };
}

fn test_bounded_queue_coalesce_book() {
    let q = new_bounded_queue();
    // Reduce capacity artificially for test
    q.max_messages = 2;


    let d1 = QueueItem {
        channel: "market:m1:book",
        msg_type: "book.delta",
        text: "delta 101",
        bytes_len: 10,
        book_seq: 101,
        from_seq: 100,
        owner_epoch: 1,
        levels: [domain.Level { side: "bid", yes_price: 45, qty: 12 }],
        is_control: false
    };
    let d2 = QueueItem {
        channel: "market:m1:book",
        msg_type: "book.delta",
        text: "delta 102",
        bytes_len: 10,
        book_seq: 102,
        from_seq: 101,
        owner_epoch: 1,
        levels: [domain.Level { side: "bid", yes_price: 45, qty: 15 }],
        is_control: false
    };
    let d3 = QueueItem {
        channel: "market:m1:book",
        msg_type: "book.delta",
        text: "delta 103",
        bytes_len: 10,
        book_seq: 103,
        from_seq: 102,
        owner_epoch: 1,
        levels: [domain.Level { side: "ask", yes_price: 55, qty: 8 }],
        is_control: false
    };

    assert(offer(q, d1, 1000));
    assert(offer(q, d2, 1000));
    // Third offer should trigger coalesce of d1 and d2 into merged 100..102, making room for d3!
    assert(offer(q, d3, 1000));

    assert(queue_len(q) <= 2);
}

fn test_market_hub_lifecycle() {
    let h = new_market_hub("m_test");
    let q1 = new_bounded_queue();

    let snap_item = hub_join(h, "c1", q1);
    assert(snap_item.msg_type == "book.snapshot");
    assert(subscriber_count(h) == 1);

    let rem = hub_leave(h, "c1", 1000);
    assert(rem == 0);
    assert(!should_stop(h, 15000));
    // After 30s idle
    assert(should_stop(h, 32000));
}

fn test_service_subscribe_limits_and_auth() {
    let store = make_fake_store();
    let s = new_stream_service(store);

    // Anonymous connection
    let _q_anon = register_connection(s, "conn_anon", "", "");

    // Should reject "me" for anonymous
    let res_anon = subscribe(s, "conn_anon", ["cards", "me"], 1000);
    guard let accepted = res_anon else {
        panic("subscribe failed unexpectedly");
    }
    assert(len(accepted) == 1);
    assert(accepted[0] == "cards");

    // Authenticated connection
    let _q_auth = register_connection(s, "conn_auth", "acc_1", "sess_1");
    let res_auth = subscribe(s, "conn_auth", ["me", "market:m1:book"], 1000);
    guard let accepted_auth = res_auth else {
        panic("subscribe auth failed");
    }
    assert(len(accepted_auth) == 2);

    // Rate limiting: 21 subscribe operations should fail with RATE_LIMITED
    let i = 0;
    let rate_limited = false;
    while i < 22 {
        let r = subscribe(s, "conn_auth", ["cards"], 1000 + i);
        if let _ok = r {
        } else let e = err_of(r) {
            if e == "RATE_LIMITED" {
                rate_limited = true;
            }
        }
        i += 1;
    }
    assert(rate_limited);
}

fn test_service_resync_me() {
    let store = make_fake_store();
    let s = new_stream_service(store);
    let q = register_connection(s, "conn_1", "acc_1", "sess_1");

    // Step 1: client sends resync(me) without generation -> service sends resync.begin
    assert(resync(s, "conn_1", "me", "", 1000));
    let opt_begin = poll(q);
    guard let item_begin = opt_begin else {
        panic("expected resync.begin in queue");
    }
    assert(item_begin.msg_type == "resync.begin");

    // Step 2: client acknowledges baseline with generation -> service sends resync.complete
    assert(resync(s, "conn_1", "me", "gen_123", 2000));
    let opt_complete = poll(q);
    guard let item_complete = opt_complete else {
        panic("expected resync.complete in queue");
    }
    assert(item_complete.msg_type == "resync.complete");
}

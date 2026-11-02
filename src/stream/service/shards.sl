import "../domain" as domain;

pub gc struct ShardSubscriber {
    conn_id: str,
    queue: BoundedQueue
}

pub gc struct ShardManager {
    lock: mutex,
    account_subs: map[str][ShardSubscriber]
}

pub fn new_shard_manager() -> ShardManager {
    let empty_map: map[str][ShardSubscriber] = {};
    return ShardManager {
        lock: make_mutex(),
        account_subs: empty_map
    };
}

pub fn register_account(sm: ShardManager, account_id: str, conn_id: str, q: BoundedQueue) {
    mutex_lock(sm.lock);
    let subs: [ShardSubscriber] = [];
    if has(sm.account_subs, account_id) {
        subs = sm.account_subs[account_id];
    }
    // Check if conn_id already registered
    let found = false;
    for s in subs {
        if s.conn_id == conn_id {
            found = true;
        }
    }
    if !found {
        push(subs, ShardSubscriber { conn_id: conn_id, queue: q });
        sm.account_subs[account_id] = subs;
    }
    mutex_unlock(sm.lock);
}

pub fn unregister_account(sm: ShardManager, account_id: str, conn_id: str) {
    mutex_lock(sm.lock);
    if has(sm.account_subs, account_id) {
        let subs = sm.account_subs[account_id];
        let next: [ShardSubscriber] = [];
        for s in subs {
            if s.conn_id != conn_id {
                push(next, s);
            }
        }
        if len(next) > 0 {
            sm.account_subs[account_id] = next;
        } else {
            del(sm.account_subs, account_id);
        }
    }
    mutex_unlock(sm.lock);
}

pub fn unregister_connection_all(sm: ShardManager, conn_id: str) {
    mutex_lock(sm.lock);
    let empty_keys: [str] = [];
    for acc_id, subs in sm.account_subs {
        let next: [ShardSubscriber] = [];
        for s in subs {
            if s.conn_id != conn_id {
                push(next, s);
            }
        }
        if len(next) > 0 {
            sm.account_subs[acc_id] = next;
        } else {
            push(empty_keys, acc_id);
        }
    }
    for k in empty_keys {
        del(sm.account_subs, k);
    }
    mutex_unlock(sm.lock);
}

pub fn dispatch_private_event(sm: ShardManager, msg: StreamMessage, now_ms: int) {
    mutex_lock(sm.lock);
    if !has(sm.account_subs, msg.account_id) {
        mutex_unlock(sm.lock);
        return;
    }
    let subs = sm.account_subs[msg.account_id];
    let text = domain.make_event_envelope(msg.event_id, "me", msg.msg_type,
        0, 0, 0, "", msg.payload);
    let item = QueueItem {
        channel: "me",
        msg_type: msg.msg_type,
        text: text,
        bytes_len: len(text),
        book_seq: 0,
        from_seq: 0,
        owner_epoch: 0,
        levels: [],
        is_control: false
    };

    for s in subs {
        let _sent = offer(s.queue, item, now_ms);
    }
    mutex_unlock(sm.lock);
}

import "../domain" as domain;

pub gc struct QueueItem {
    channel: str,
    msg_type: str,
    text: str,
    bytes_len: int,
    book_seq: int,
    from_seq: int,
    owner_epoch: int,
    levels: [domain.Level],
    is_control: bool
}

pub gc struct BoundedQueue {
    lock: mutex,
    items: [QueueItem],
    total_bytes: int,
    max_messages: int,
    max_bytes: int,
    overflow_start_ms: int,
    is_paused_me: bool,
    notify: chan[int]
}

pub fn new_bounded_queue() -> BoundedQueue {
    let empty_items: [QueueItem] = [];
    return BoundedQueue {
        lock: make_mutex(),
        items: empty_items,
        total_bytes: 0,
        max_messages: domain.max_outbound_queue_messages(),
        max_bytes: domain.max_outbound_queue_bytes(),
        overflow_start_ms: 0,
        is_paused_me: false,
        notify: make_chan(1)
    };
}

fn try_notify(q: BoundedQueue) {
    select {
        case chan_send(q.notify, 1) { }
        default { }
    }
}

pub fn queue_len(q: BoundedQueue) -> int {
    mutex_lock(q.lock);
    let l = len(q.items);
    mutex_unlock(q.lock);
    return l;
}

pub fn queue_bytes(q: BoundedQueue) -> int {
    mutex_lock(q.lock);
    let b = q.total_bytes;
    mutex_unlock(q.lock);
    return b;
}

pub fn is_me_paused(q: BoundedQueue) -> bool {
    mutex_lock(q.lock);
    let p = q.is_paused_me;
    mutex_unlock(q.lock);
    return p;
}

pub fn unpause_me(q: BoundedQueue) {
    mutex_lock(q.lock);
    q.is_paused_me = false;
    mutex_unlock(q.lock);
}

pub fn check_slow_consumer(q: BoundedQueue, now_ms: int) -> bool {
    mutex_lock(q.lock);
    let is_slow = false;
    if q.overflow_start_ms > 0 && (now_ms - q.overflow_start_ms) >= 10000 {
        is_slow = true;
    }
    mutex_unlock(q.lock);
    return is_slow;
}

pub fn close_bounded_queue(q: BoundedQueue) {
    mutex_lock(q.lock);
    let items_clear: [QueueItem] = [];
    q.items = items_clear;
    q.total_bytes = 0;
    mutex_unlock(q.lock);
    chan_close(q.notify);
}

pub fn poll(q: BoundedQueue) -> opt[QueueItem] {
    mutex_lock(q.lock);
    if len(q.items) == 0 {
        mutex_unlock(q.lock);
        let empty: opt[QueueItem] = none;
        return empty;
    }
    let item = q.items[0];
    let next: [QueueItem] = [];
    let i = 1;
    while i < len(q.items) {
        push(next, q.items[i]);
        i += 1;
    }
    q.items = next;
    q.total_bytes -= item.bytes_len;
    if q.total_bytes < 0 {
        q.total_bytes = 0;
    }

    // Reset overflow timer if queue drops below 50% capacity
    if len(q.items) < q.max_messages / 2 && q.total_bytes < q.max_bytes / 2 {
        q.overflow_start_ms = 0;
    }

    mutex_unlock(q.lock);
    return some(item);
}

// Merges contiguous book deltas in the queue for the same channel and epoch
fn coalesce_book_deltas(q: BoundedQueue, channel: str) -> bool {
    let non_book: [QueueItem] = [];
    let book_deltas: [QueueItem] = [];

    for it in q.items {
        if it.channel == channel && it.msg_type == "book.delta" {
            push(book_deltas, it);
        } else {
            push(non_book, it);
        }
    }

    if len(book_deltas) <= 1 {
        return false;
    }

    // Check contiguity and same epoch
    let epoch = book_deltas[0].owner_epoch;
    let base_seq = book_deltas[0].from_seq;
    let final_seq = book_deltas[len(book_deltas) - 1].book_seq;
    let all_levels: [domain.Level] = [];

    let contiguous = true;
    let prev_seq = base_seq;
    for bd in book_deltas {
        if bd.owner_epoch != epoch || bd.from_seq != prev_seq {
            contiguous = false;
        }
        prev_seq = bd.book_seq;
        all_levels = domain.apply_levels_update(all_levels, bd.levels);
    }

    if !contiguous {
        return false;
    }

    // Build single merged delta item
    let payload = "{\"levels\":[]}";
    let text = domain.make_event_envelope("merged_" + to_str(base_seq) + "_" + to_str(final_seq),
        channel, "book.delta", final_seq, base_seq, epoch, "", payload);
    let bytes_len = len(text);

    let merged_item = QueueItem {
        channel: channel,
        msg_type: "book.delta",
        text: text,
        bytes_len: bytes_len,
        book_seq: final_seq,
        from_seq: base_seq,
        owner_epoch: epoch,
        levels: all_levels,
        is_control: false
    };

    let new_items: [QueueItem] = [];
    let new_bytes = 0;
    for it in non_book {
        push(new_items, it);
        new_bytes += it.bytes_len;
    }
    push(new_items, merged_item);
    new_bytes += bytes_len;

    q.items = new_items;
    q.total_bytes = new_bytes;
    return true;
}

pub fn offer(q: BoundedQueue, item: QueueItem, now_ms: int) -> bool {
    mutex_lock(q.lock);

    // If channel is "me" and private events are paused, drop unless it's a resync control
    if item.channel == "me" && q.is_paused_me && !item.is_control {
        mutex_unlock(q.lock);
        return false;
    }

    let is_full = len(q.items) >= q.max_messages || (q.total_bytes + item.bytes_len) > q.max_bytes;

    if is_full {
        if q.overflow_start_ms == 0 {
            q.overflow_start_ms = now_ms;
        }

        // Apply channel-specific backpressure rules
        if item.channel == "cards" {
            // Keep only newest cards.tick: replace existing cards.tick
            let next_items: [QueueItem] = [];
            let next_bytes = 0;
            for it in q.items {
                if it.channel != "cards" {
                    push(next_items, it);
                    next_bytes += it.bytes_len;
                }
            }
            push(next_items, item);
            next_bytes += item.bytes_len;
            q.items = next_items;
            q.total_bytes = next_bytes;
            mutex_unlock(q.lock);
            try_notify(q);
            return true;
        }

        if item.channel == "me" {
            // Pause private events and enqueue resync_required
            q.is_paused_me = true;
            let next_items: [QueueItem] = [];
            let next_bytes = 0;
            for it in q.items {
                if it.channel != "me" || it.is_control {
                    push(next_items, it);
                    next_bytes += it.bytes_len;
                }
            }
            let resync_text = domain.make_event_envelope("evt_resync_req", "me", "resync_required",
                0, 0, 0, "", "{\"channel\":\"me\"}");
            let resync_item = QueueItem {
                channel: "me",
                msg_type: "resync_required",
                text: resync_text,
                bytes_len: len(resync_text),
                book_seq: 0,
                from_seq: 0,
                owner_epoch: 0,
                levels: [],
                is_control: true
            };
            push(next_items, resync_item);
            next_bytes += resync_item.bytes_len;
            q.items = next_items;
            q.total_bytes = next_bytes;
            mutex_unlock(q.lock);
            try_notify(q);
            return true;
        }

        if strings.has_suffix(item.channel, ":trades") {
            // Drop oldest trade, enqueue trades.gap
            let next_items: [QueueItem] = [];
            let next_bytes = 0;
            let dropped_trade = false;
            for it in q.items {
                if !dropped_trade && it.channel == item.channel && it.msg_type == "trade" {
                    dropped_trade = true;
                } else {
                    push(next_items, it);
                    next_bytes += it.bytes_len;
                }
            }
            let gap_text = domain.make_event_envelope("evt_trade_gap", item.channel, "trades.gap",
                0, 0, 0, "", "{\"since_ts\":\"\"}");
            let gap_item = QueueItem {
                channel: item.channel,
                msg_type: "trades.gap",
                text: gap_text,
                bytes_len: len(gap_text),
                book_seq: 0,
                from_seq: 0,
                owner_epoch: 0,
                levels: [],
                is_control: true
            };
            push(next_items, gap_item);
            next_bytes += gap_item.bytes_len;
            q.items = next_items;
            q.total_bytes = next_bytes;
            mutex_unlock(q.lock);
            try_notify(q);
            return true;
        }

        if strings.has_suffix(item.channel, ":book") && item.msg_type == "book.delta" {
            // Try merging deltas
            let merged = coalesce_book_deltas(q, item.channel);
            if merged && len(q.items) < q.max_messages && (q.total_bytes + item.bytes_len) <= q.max_bytes {
                push(q.items, item);
                q.total_bytes += item.bytes_len;
                mutex_unlock(q.lock);
                try_notify(q);
                return true;
            }

            // If still full: drop all book deltas for that market, reserve a book.reset
            let next_items: [QueueItem] = [];
            let next_bytes = 0;
            for it in q.items {
                if it.channel != item.channel || it.is_control {
                    push(next_items, it);
                    next_bytes += it.bytes_len;
                }
            }
            let reset_text = domain.make_event_envelope("evt_book_reset", item.channel, "book.reset",
                item.book_seq, 0, item.owner_epoch, "", "{\"reason\":\"slow_consumer_coalesce_overflow\"}");
            let reset_item = QueueItem {
                channel: item.channel,
                msg_type: "book.reset",
                text: reset_text,
                bytes_len: len(reset_text),
                book_seq: item.book_seq,
                from_seq: 0,
                owner_epoch: item.owner_epoch,
                levels: [],
                is_control: true
            };
            push(next_items, reset_item);
            next_bytes += reset_item.bytes_len;
            q.items = next_items;
            q.total_bytes = next_bytes;
            mutex_unlock(q.lock);
            try_notify(q);
            return true;
        }

        // Control messages always get reserved space if not grossly overflowing
        if item.is_control && len(q.items) < (q.max_messages + 16) {
            push(q.items, item);
            q.total_bytes += item.bytes_len;
            mutex_unlock(q.lock);
            try_notify(q);
            return true;
        }

        mutex_unlock(q.lock);
        return false;
    }

    push(q.items, item);
    q.total_bytes += item.bytes_len;
    mutex_unlock(q.lock);
    try_notify(q);
    return true;
}

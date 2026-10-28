import "strings";
import "../domain" as domain;

pub gc struct MarketHub {
    market_id: str,
    lock: mutex,
    subscribers: map[str]BoundedQueue,
    book_seq: int,
    owner_epoch: int,
    yes_bids: [domain.Level],
    yes_asks: [domain.Level],
    value: int,
    min_price: int,
    max_price: int,
    tick: int,
    health: str,
    mode: str,
    idle_since_ms: int,
    active: bool
}

pub fn new_market_hub(market_id: str) -> MarketHub {
    let empty_subs: map[str]BoundedQueue = {};
    let empty_bids: [domain.Level] = [];
    let empty_asks: [domain.Level] = [];
    return MarketHub {
        market_id: market_id,
        lock: make_mutex(),
        subscribers: empty_subs,
        book_seq: 0,
        owner_epoch: 0,
        yes_bids: empty_bids,
        yes_asks: empty_asks,
        value: 100,
        min_price: 1,
        max_price: 99,
        tick: 1,
        health: "INITIALIZING",
        mode: "OPEN",
        idle_since_ms: 0,
        active: true
    };
}

pub fn init_from_snapshot(hub: MarketHub, snap: RuntimeBookSnapshot) {
    mutex_lock(hub.lock);
    hub.book_seq = snap.book_seq;
    hub.owner_epoch = snap.owner_epoch;
    hub.value = snap.value;
    hub.min_price = snap.min_price;
    hub.max_price = snap.max_price;
    hub.tick = snap.tick;
    hub.health = snap.health;
    hub.mode = snap.mode;
    hub.yes_bids = snap.bids;
    hub.yes_asks = snap.asks;
    mutex_unlock(hub.lock);
}

pub fn make_snapshot_json(hub: MarketHub) -> str {
    // Generate levels JSON array
    let levels_parts: [str] = [];
    for b in hub.yes_bids {
        push(levels_parts, "{\"side\":\"bid\",\"yes_price\":" + to_str(b.yes_price) + ",\"qty\":\"" + to_str(b.qty) + "\"}");
    }
    for a in hub.yes_asks {
        push(levels_parts, "{\"side\":\"ask\",\"yes_price\":" + to_str(a.yes_price) + ",\"qty\":\"" + to_str(a.qty) + "\"}");
    }
    let levels_json = "[" + strings.join(levels_parts, ",") + "]";

    return "{\"depth\":50,\"value\":" + to_str(hub.value) +
        ",\"price_band\":{\"min\":" + to_str(hub.min_price) + ",\"max\":" + to_str(hub.max_price) + ",\"tick\":" + to_str(hub.tick) + "}" +
        ",\"health\":\"" + hub.health + "\",\"mode\":\"" + hub.mode + "\",\"levels\":" + levels_json + "}";
}

pub fn build_snapshot_queue_item(hub: MarketHub, is_reset: bool) -> QueueItem {
    mutex_lock(hub.lock);
    let channel = "market:" + hub.market_id + ":book";
    let msg_type = "book.snapshot";
    if is_reset {
        msg_type = "book.reset";
    }
    let payload = make_snapshot_json(hub);
    let text = domain.make_event_envelope("snap_" + to_str(hub.book_seq), channel, msg_type,
        hub.book_seq, 0, hub.owner_epoch, "", payload);
    let all_levels: [domain.Level] = [];
    for b in hub.yes_bids { push(all_levels, b); }
    for a in hub.yes_asks { push(all_levels, a); }
    let item = QueueItem {
        channel: channel,
        msg_type: msg_type,
        text: text,
        bytes_len: len(text),
        book_seq: hub.book_seq,
        from_seq: 0,
        owner_epoch: hub.owner_epoch,
        levels: all_levels,
        is_control: is_reset
    };
    mutex_unlock(hub.lock);
    return item;
}

pub fn hub_join(hub: MarketHub, conn_id: str, q: BoundedQueue) -> QueueItem {
    mutex_lock(hub.lock);
    hub.subscribers[conn_id] = q;
    hub.idle_since_ms = 0;
    mutex_unlock(hub.lock);
    return build_snapshot_queue_item(hub, false);
}

pub fn hub_leave(hub: MarketHub, conn_id: str, now_ms: int) -> int {
    mutex_lock(hub.lock);
    if has(hub.subscribers, conn_id) {
        del(hub.subscribers, conn_id);
    }
    let remaining = len(hub.subscribers);
    if remaining == 0 && hub.idle_since_ms == 0 {
        hub.idle_since_ms = now_ms;
    }
    mutex_unlock(hub.lock);
    return remaining;
}

pub fn should_stop(hub: MarketHub, now_ms: int) -> bool {
    mutex_lock(hub.lock);
    let stop = false;
    if len(hub.subscribers) == 0 && hub.idle_since_ms > 0 && (now_ms - hub.idle_since_ms) >= 30000 {
        stop = true;
        hub.active = false;
    }
    mutex_unlock(hub.lock);
    return stop;
}

pub fn subscriber_count(hub: MarketHub) -> int {
    mutex_lock(hub.lock);
    let c = len(hub.subscribers);
    mutex_unlock(hub.lock);
    return c;
}

pub fn broadcast_reset(hub: MarketHub, now_ms: int) {
    let reset_item = build_snapshot_queue_item(hub, true);
    mutex_lock(hub.lock);
    for cid, q in hub.subscribers {
        let _sent = offer(q, reset_item, now_ms);
    }
    mutex_unlock(hub.lock);
}

pub fn dispatch_delta(hub: MarketHub, msg: StreamMessage, levels: [domain.Level], now_ms: int) {
    mutex_lock(hub.lock);

    // Contiguity check: book_seq must be previous + 1, owner_epoch must match
    if hub.book_seq > 0 && (msg.owner_epoch != hub.owner_epoch || msg.market_seq != (hub.book_seq + 1)) {
        mutex_unlock(hub.lock);
        // Epoch change or sequence gap: trigger broadcast reset
        broadcast_reset(hub, now_ms);
        return;
    }

    let from_seq = hub.book_seq;
    hub.book_seq = msg.market_seq;
    hub.owner_epoch = msg.owner_epoch;
    hub.yes_bids = domain.apply_levels_update(hub.yes_bids, levels);
    hub.yes_asks = domain.apply_levels_update(hub.yes_asks, levels);

    let channel = "market:" + hub.market_id + ":book";
    let text = domain.make_event_envelope(msg.event_id, channel, "book.delta",
        hub.book_seq, from_seq, hub.owner_epoch, "", msg.payload);
    let item = QueueItem {
        channel: channel,
        msg_type: "book.delta",
        text: text,
        bytes_len: len(text),
        book_seq: hub.book_seq,
        from_seq: from_seq,
        owner_epoch: hub.owner_epoch,
        levels: levels,
        is_control: false
    };

    for cid, q in hub.subscribers {
        let _sent = offer(q, item, now_ms);
    }
    mutex_unlock(hub.lock);
}

pub fn dispatch_trade(hub: MarketHub, msg: StreamMessage, now_ms: int) {
    mutex_lock(hub.lock);
    let channel = "market:" + hub.market_id + ":trades";
    let text = domain.make_event_envelope(msg.event_id, channel, "trade",
        0, 0, 0, "", msg.payload);
    let item = QueueItem {
        channel: channel,
        msg_type: "trade",
        text: text,
        bytes_len: len(text),
        book_seq: 0,
        from_seq: 0,
        owner_epoch: 0,
        levels: [],
        is_control: false
    };

    for cid, q in hub.subscribers {
        let _sent = offer(q, item, now_ms);
    }
    mutex_unlock(hub.lock);
}

pub fn dispatch_status(hub: MarketHub, msg: StreamMessage, now_ms: int) {
    mutex_lock(hub.lock);
    let channel = "market:" + hub.market_id + ":status";
    let text = domain.make_event_envelope(msg.event_id, channel, "market.status",
        0, 0, 0, "", msg.payload);
    let item = QueueItem {
        channel: channel,
        msg_type: "market.status",
        text: text,
        bytes_len: len(text),
        book_seq: 0,
        from_seq: 0,
        owner_epoch: 0,
        levels: [],
        is_control: false
    };

    for cid, q in hub.subscribers {
        let _sent = offer(q, item, now_ms);
    }
    mutex_unlock(hub.lock);
}

import "strings";
import "../domain" as domain;

pub gc struct CardsTicker {
    lock: mutex,
    subscribers: map[str]BoundedQueue,
    last_tick_ms: int
}

pub fn new_cards_ticker() -> CardsTicker {
    let empty_subs: map[str]BoundedQueue = {};
    return CardsTicker {
        lock: make_mutex(),
        subscribers: empty_subs,
        last_tick_ms: 0
    };
}

pub fn subscribe_cards(t: CardsTicker, conn_id: str, q: BoundedQueue) {
    mutex_lock(t.lock);
    t.subscribers[conn_id] = q;
    mutex_unlock(t.lock);
}

pub fn unsubscribe_cards(t: CardsTicker, conn_id: str) {
    mutex_lock(t.lock);
    if has(t.subscribers, conn_id) {
        del(t.subscribers, conn_id);
    }
    mutex_unlock(t.lock);
}

pub fn cards_subscriber_count(t: CardsTicker) -> int {
    mutex_lock(t.lock);
    let c = len(t.subscribers);
    mutex_unlock(t.lock);
    return c;
}

pub fn dispatch_cards_tick(t: CardsTicker, items: [CardStatItem], now_ms: int) {
    mutex_lock(t.lock);
    if len(t.subscribers) == 0 {
        mutex_unlock(t.lock);
        return;
    }

    t.last_tick_ms = now_ms;

    let parts: [str] = [];
    for it in items {
        let entry = "{\"market_id\":\"" + it.market_id + "\",\"last_price\":" + to_str(it.last_price) +
            ",\"chance_pct\":" + to_str(it.chance_pct) + ",\"yes_ask\":" + to_str(it.yes_ask) +
            ",\"no_ask\":" + to_str(it.no_ask) + ",\"volume_units\":" + to_str(it.volume_units) +
            ",\"change_24h\":" + to_str(it.change_24h) + "}";
        push(parts, entry);
    }
    let payload = "{\"items\":[" + strings.join(parts, ",") + "]}";

    let text = domain.make_event_envelope("tick_" + to_str(now_ms), "cards", "cards.tick",
        0, 0, 0, "", payload);
    let qitem = QueueItem {
        channel: "cards",
        msg_type: "cards.tick",
        text: text,
        bytes_len: len(text),
        book_seq: 0,
        from_seq: 0,
        owner_epoch: 0,
        levels: [],
        is_control: false
    };

    for cid, q in t.subscribers {
        let _sent = offer(q, qitem, now_ms);
    }
    mutex_unlock(t.lock);
}

import "strings";
import "../domain" as domain;

pub gc struct Connection {
    conn_id: str,
    account_id: str,
    session_id: str,
    channels: map[str]bool,
    queue: BoundedQueue,
    sub_window_start_ms: int,
    sub_count: int
}

pub gc struct StreamService[C] {
    store: StreamStore[C],
    hubs_lock: mutex,
    hubs: map[str]MarketHub,
    shards: ShardManager,
    ticker: CardsTicker,
    conns_lock: mutex,
    conns: map[str]Connection
}

pub fn new_stream_service[C](store: StreamStore[C]) -> StreamService[C] {
    let empty_hubs: map[str]MarketHub = {};
    let empty_conns: map[str]Connection = {};
    return StreamService[C] {
        store: store,
        hubs_lock: make_mutex(),
        hubs: empty_hubs,
        shards: new_shard_manager(),
        ticker: new_cards_ticker(),
        conns_lock: make_mutex(),
        conns: empty_conns
    };
}

pub fn register_connection[C](s: StreamService[C], conn_id: str, account_id: str, session_id: str) -> BoundedQueue {
    let q = new_bounded_queue();
    let empty_chans: map[str]bool = {};
    let c = Connection {
        conn_id: conn_id,
        account_id: account_id,
        session_id: session_id,
        channels: empty_chans,
        queue: q,
        sub_window_start_ms: 0,
        sub_count: 0
    };
    mutex_lock(s.conns_lock);
    s.conns[conn_id] = c;
    mutex_unlock(s.conns_lock);
    return q;
}

pub fn unregister_connection[C](s: StreamService[C], conn_id: str, now_ms: int) {
    mutex_lock(s.conns_lock);
    let found = has(s.conns, conn_id);
    let channels: [str] = [];
    let opt_q: opt[BoundedQueue] = none;
    if found {
        opt_q = some(s.conns[conn_id].queue);
        for ch, _v in s.conns[conn_id].channels {
            push(channels, ch);
        }
        del(s.conns, conn_id);
    }
    mutex_unlock(s.conns_lock);

    if let q_val = opt_q {
        close_bounded_queue(q_val);
    }

    unsubscribe_cards(s.ticker, conn_id);
    unregister_connection_all(s.shards, conn_id);

    // Leave hubs
    for ch in channels {
        let info = domain.parse_channel(ch);
        if info.market_id != "" {
            mutex_lock(s.hubs_lock);
            if has(s.hubs, info.market_id) {
                let h = s.hubs[info.market_id];
                let _rem = hub_leave(h, conn_id, now_ms);
            }
            mutex_unlock(s.hubs_lock);
        }
    }
}

pub fn get_or_create_hub[C](s: StreamService[C], market_id: str) -> MarketHub {
    mutex_lock(s.hubs_lock);
    if has(s.hubs, market_id) {
        let h = s.hubs[market_id];
        mutex_unlock(s.hubs_lock);
        return h;
    }
    let h = new_market_hub(market_id);
    // Initialize snapshot from store if available
    let fetch = s.store.get_book_view;
    let snap_res = fetch(s.store.context, market_id);
    if let snap_opt = snap_res {
        if let snap = snap_opt {
            init_from_snapshot(h, snap);
        }
    }
    s.hubs[market_id] = h;
    mutex_unlock(s.hubs_lock);
    return h;
}

pub fn subscribe[C](s: StreamService[C], conn_id: str, requested: [str], now_ms: int) -> result[[str], str] {
    mutex_lock(s.conns_lock);
    if !has(s.conns, conn_id) {
        mutex_unlock(s.conns_lock);
        return err("UNKNOWN_CONNECTION");
    }
    let c = s.conns[conn_id];

    // Rate limiting: 20 subscribe operations per 10s
    if c.sub_window_start_ms == 0 || (now_ms - c.sub_window_start_ms) > 10000 {
        c.sub_window_start_ms = now_ms;
        c.sub_count = 1;
    } else {
        c.sub_count += 1;
        if c.sub_count > domain.max_subscribe_ops_per_10s() {
            mutex_unlock(s.conns_lock);
            return err("RATE_LIMITED");
        }
    }

    // Capacity limit: max 50 channels
    if (len(c.channels) + len(requested)) > domain.max_channels_per_connection() {
        mutex_unlock(s.conns_lock);
        return err("CHANNEL_LIMIT_EXCEEDED");
    }

    let accepted: [str] = [];
    for ch in requested {
        let info = domain.parse_channel(ch);
        if !info.valid {
            continue;
        }
        if info.is_private && c.account_id == "" {
            // Cannot subscribe to me without authentication
            continue;
        }

        c.channels[ch] = true;
        push(accepted, ch);

        if info.kind == "cards" {
            subscribe_cards(s.ticker, conn_id, c.queue);
        } else if info.kind == "me" {
            register_account(s.shards, c.account_id, conn_id, c.queue);
        } else if info.market_id != "" {
            let h = get_or_create_hub(s, info.market_id);
            if info.kind == "market.book" {
                let snap_item = hub_join(h, conn_id, c.queue);
                let _sent = offer(c.queue, snap_item, now_ms);
            } else {
                let _dummy = hub_join(h, conn_id, c.queue);
            }
        }
    }

    mutex_unlock(s.conns_lock);
    return ok(accepted);
}

pub fn unsubscribe[C](s: StreamService[C], conn_id: str, requested: [str], now_ms: int) -> [str] {
    mutex_lock(s.conns_lock);
    if !has(s.conns, conn_id) {
        mutex_unlock(s.conns_lock);
        let empty: [str] = [];
        return empty;
    }
    let c = s.conns[conn_id];
    let removed: [str] = [];

    for ch in requested {
        if has(c.channels, ch) {
            del(c.channels, ch);
            push(removed, ch);

            let info = domain.parse_channel(ch);
            if info.kind == "cards" {
                unsubscribe_cards(s.ticker, conn_id);
            } else if info.kind == "me" {
                unregister_account(s.shards, c.account_id, conn_id);
            } else if info.market_id != "" {
                mutex_lock(s.hubs_lock);
                if has(s.hubs, info.market_id) {
                    let h = s.hubs[info.market_id];
                    let _rem = hub_leave(h, conn_id, now_ms);
                }
                mutex_unlock(s.hubs_lock);
            }
        }
    }

    mutex_unlock(s.conns_lock);
    return removed;
}

pub fn resync[C](s: StreamService[C], conn_id: str, channel: str, generation: str, now_ms: int) -> bool {
    mutex_lock(s.conns_lock);
    if !has(s.conns, conn_id) {
        mutex_unlock(s.conns_lock);
        return false;
    }
    let c = s.conns[conn_id];
    let q = c.queue;
    mutex_unlock(s.conns_lock);

    if channel == "me" {
        unpause_me(q);
        if generation == "" {
            // Step 2: send resync.begin
            let gen = "gen_" + to_str(now_ms);
            let text = domain.make_control_message("resync.begin", "{\"channel\":\"me\",\"generation\":\"" + gen + "\"}");
            let item = QueueItem {
                channel: "me",
                msg_type: "resync.begin",
                text: text,
                bytes_len: len(text),
                book_seq: 0,
                from_seq: 0,
                owner_epoch: 0,
                levels: [],
                is_control: true
            };
            return offer(q, item, now_ms);
        } else {
            // Step 4: client acknowledged baseline, send resync.complete
            let text = domain.make_control_message("resync.complete", "{\"channel\":\"me\",\"generation\":\"" + generation + "\"}");
            let item = QueueItem {
                channel: "me",
                msg_type: "resync.complete",
                text: text,
                bytes_len: len(text),
                book_seq: 0,
                from_seq: 0,
                owner_epoch: 0,
                levels: [],
                is_control: true
            };
            return offer(q, item, now_ms);
        }
    }

    let info = domain.parse_channel(channel);
    if info.kind == "market.book" && info.market_id != "" {
        let h = get_or_create_hub(s, info.market_id);
        let snap_item = build_snapshot_queue_item(h, false);
        return offer(q, snap_item, now_ms);
    }

    return false;
}

pub fn find_revoked_connections[C](s: StreamService[C], session_id: str) -> [str] {
    mutex_lock(s.conns_lock);
    let matched: [str] = [];
    for cid, c in s.conns {
        if c.session_id == session_id && session_id != "" {
            push(matched, cid);
        }
    }
    mutex_unlock(s.conns_lock);
    return matched;
}

pub fn revoke_session[C](s: StreamService[C], session_id: str, now_ms: int) {
    mutex_lock(s.conns_lock);
    let empty_levels: [domain.Level] = [];
    for cid, c in s.conns {
        if c.session_id == session_id && session_id != "" {
            let item = QueueItem {
                channel: "control",
                msg_type: "session.revoked",
                text: "session revoked",
                bytes_len: 15,
                book_seq: 0,
                from_seq: 0,
                owner_epoch: 0,
                levels: empty_levels,
                is_control: true
            };
            let _sent = offer(c.queue, item, now_ms);
        }
    }
    mutex_unlock(s.conns_lock);
}

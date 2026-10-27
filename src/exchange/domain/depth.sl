pub struct DepthAt { yes_price: int, bid_qty: int, ask_qty: int }
pub struct Depth { bids: [LevelDelta], asks: [LevelDelta], bid_count: int, ask_count: int }

pub fn depth_buffer(capacity: int) -> Depth {
    assert(capacity > 0 && capacity <= 1000);
    let bids: [LevelDelta] = []; let asks: [LevelDelta] = [];
    for i in 0..capacity {
        push(bids, LevelDelta { side: "bid", yes_price: 0, new_level_qty: 0 });
        push(asks, LevelDelta { side: "ask", yes_price: 0, new_level_qty: 0 });
    }
    return Depth { bids: bids, asks: asks, bid_count: 0, ask_count: 0 };
}

pub fn depth_at(b: &Book, price: int) -> DepthAt {
    let bid = 0; let ask = 0;
    if price >= b.policy.min_price && price <= b.policy.max_price { bid = b.bids[price].total; ask = b.asks[price].total; }
    return DepthAt { yes_price: price, bid_qty: bid, ask_qty: ask };
}

pub fn top_levels(b: &Book, n: int, out: &mut Depth) -> str {
    out.bid_count = 0; out.ask_count = 0;
    if n < 0 || n > len(out.bids) || n > len(out.asks) { return "NEED_CAPACITY"; }
    let price = b.best_bid;
    while price >= b.policy.min_price && out.bid_count < n {
        let level = b.bids[price];
        if level.total > 0 {
            out.bids[out.bid_count] = LevelDelta { side: "bid", yes_price: price, new_level_qty: level.total };
            out.bid_count += 1;
        }
        price -= 1;
    }
    price = b.best_ask;
    while price <= b.policy.max_price && out.ask_count < n {
        let level = b.asks[price];
        if level.total > 0 {
            out.asks[out.ask_count] = LevelDelta { side: "ask", yes_price: price, new_level_qty: level.total };
            out.ask_count += 1;
        }
        price += 1;
    }
    return "";
}

pub fn grow(b: &Book, capacity: int) -> result[Book, str] {
    if capacity <= len(b.slots) { return err("INVALID_CAPACITY"); }
    return restore(snapshot(b), capacity);
}

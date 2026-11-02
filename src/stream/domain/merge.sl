import "json";
import "strings";

gc struct RawDeltaPayload {
    levels: [Level]
}

pub fn parse_delta_levels(payload_json: str) -> [Level] {
    let empty: [Level] = [];
    if len(payload_json) == 0 {
        return empty;
    }
    let decoded: result[RawDeltaPayload, str] = json.decode(payload_json);
    if let r = decoded {
        return r.levels;
    }
    return empty;
}

pub gc struct Level {
    side: str,      // "bid" or "ask"
    yes_price: int,
    qty: int
}

pub gc struct DeltaRange {
    from_seq: int,
    book_seq: int,
    owner_epoch: int,
    levels: [Level],
    view_replacement: str
}

pub gc struct MirroredBook {
    yes_bids: [Level],
    yes_asks: [Level],
    no_bids: [Level],
    no_asks: [Level]
}

pub fn level_equals(a: Level, b: Level) -> bool {
    return a.side == b.side && a.yes_price == b.yes_price && a.qty == b.qty;
}

pub fn sort_bids_descending(levels: [Level]) -> [Level] {
    let out: [Level] = [];
    for l in levels {
        push(out, l);
    }
    let n = len(out);
    for i in 1..n {
        let key = out[i];
        let j = i - 1;
        while j >= 0 && out[j].yes_price < key.yes_price {
            out[j + 1] = out[j];
            j = j - 1;
        }
        out[j + 1] = key;
    }
    return out;
}

pub fn sort_asks_ascending(levels: [Level]) -> [Level] {
    let out: [Level] = [];
    for l in levels {
        push(out, l);
    }
    let n = len(out);
    for i in 1..n {
        let key = out[i];
        let j = i - 1;
        while j >= 0 && out[j].yes_price > key.yes_price {
            out[j + 1] = out[j];
            j = j - 1;
        }
        out[j + 1] = key;
    }
    return out;
}

pub fn apply_levels_update(existing: [Level], updates: [Level]) -> [Level] {
    let map_qty: map[str]int = {};
    let seen_keys: [str] = [];

    for l in existing {
        let k = l.side + ":" + to_str(l.yes_price);
        map_qty[k] = l.qty;
        push(seen_keys, k);
    }

    for u in updates {
        let k = u.side + ":" + to_str(u.yes_price);
        map_qty[k] = u.qty;
        let already = false;
        for s in seen_keys {
            if s == k { already = true; }
        }
        if !already {
            push(seen_keys, k);
        }
    }

    let out: [Level] = [];
    for k in seen_keys {
        let q = map_qty[k];
        if q > 0 {
            let parts = strings.split(k, ":");
            let p = to_int(parts[1]) ?? 0;
            push(out, Level { side: parts[0], yes_price: p, qty: q });
        }
    }
    return out;

}

pub fn merge_delta_levels(deltas: [DeltaRange]) -> [Level] {
    let latest_levels: [Level] = [];
    for d in deltas {
        latest_levels = apply_levels_update(latest_levels, d.levels);
    }
    return latest_levels;
}

pub fn derive_mirrored_book(yes_bids: [Level], yes_asks: [Level], value: int) -> MirroredBook {
    let no_bids: [Level] = [];
    for ask in yes_asks {
        let no_price = value - ask.yes_price;
        if no_price > 0 && no_price < value {
            push(no_bids, Level { side: "bid", yes_price: no_price, qty: ask.qty });
        }
    }

    let no_asks: [Level] = [];
    for bid in yes_bids {
        let no_price = value - bid.yes_price;
        if no_price > 0 && no_price < value {
            push(no_asks, Level { side: "ask", yes_price: no_price, qty: bid.qty });
        }
    }

    return MirroredBook {
        yes_bids: sort_bids_descending(yes_bids),
        yes_asks: sort_asks_ascending(yes_asks),
        no_bids: sort_bids_descending(no_bids),
        no_asks: sort_asks_ascending(no_asks)
    };
}

pub fn verify(b: &Book, w: &mut Workspace) -> str {
    if !workspace_fits(b, &*w) { return "WORKSPACE_MISMATCH"; }
    if !valid_policy(b.policy, w.scratch.data) || b.last_seq < 0 || b.last_price < 0 ||
       (b.mode != "OPEN" && b.mode != "SUSPENDED" && b.mode != "CLOSED") { return "INVALID_BOOK"; }
    guard let collateral = mul_units(b.pairs, b.policy.V) else { return "INVALID_SUPPLY"; }
    if collateral != b.collateral || b.free_count < 0 || b.free_count > len(b.slots) ||
       b.active_count != len(b.slots) - b.free_count || len(w.verify_seen) != len(b.slots) { return "INVALID_BOOK"; }
    for i in 0..len(w.verify_seen) { w.verify_seen[i] = 0; }
    let count = 0; let reserved_yes = 0; let reserved_no = 0;
    let best_bid = 0; let best_ask = b.policy.V;
    for side in 0..2 {
        for price in 0..(b.policy.V + 1) {
            let level = level_of(b, side == 0, price);
            let at = level.head; let previous = -1; let total = 0;
            while at >= 0 {
                if at >= len(b.slots) || w.verify_seen[at] != 0 { return "INVALID_QUEUE"; }
                w.verify_seen[at] = 1;
                let slot = b.slots[at]; let o = slot.order;
                if !slot.active || slot.generation < 1 || slot.previous != previous || o.remaining < 1 ||
                   o.accepted_seq > b.last_seq || o.tif != "GTC" || is_bid(o) != (side == 0) || yes_price(b.policy, o) != price ||
                   !valid_order_state(b.policy, o, w.scratch.data) { return "INVALID_QUEUE"; }
                if previous >= 0 {
                    let older = b.slots[previous].order;
                    if older.accepted_seq > o.accepted_seq || (older.accepted_seq == o.accepted_seq && older.id >= o.id) { return "INVALID_PRIORITY"; }
                }
                if find_order(b, o.id, w.scratch.data) != at { return "INVALID_INDEX"; }
                guard let sum = add_units(total, o.remaining) else { return "OVERFLOW"; }
                total = sum;
                if o.side == "SELL" {
                    if o.outcome == "YES" {
                        guard let next = add_units(reserved_yes, o.remaining) else { return "OVERFLOW"; }
                        reserved_yes = next;
                    } else {
                        guard let next = add_units(reserved_no, o.remaining) else { return "OVERFLOW"; }
                        reserved_no = next;
                    }
                }
                count += 1; previous = at; at = slot.next;
            }
            if previous != level.tail || total != level.total { return "INVALID_LEVEL"; }
            if total > 0 {
                if side == 0 { best_bid = price; } else if price < best_ask { best_ask = price; }
            }
        }
    }
    for i in 0..b.free_count {
        let at = b.free_slots[i];
        if at < 0 || at >= len(b.slots) || w.verify_seen[at] != 0 || b.slots[at].active { return "INVALID_FREE_LIST"; }
        w.verify_seen[at] = 2;
    }
    for i in 0..len(w.verify_seen) { if w.verify_seen[i] == 0 { return "UNREACHABLE_SLOT"; } }
    let buckets = 0;
    for bucket in b.index {
        if bucket.slot < 0 { continue; }
        if bucket.slot >= len(b.slots) || !b.slots[bucket.slot].active ||
           bucket.home != id_home(b.slots[bucket.slot].order.id, len(b.index), w.scratch.data) { return "INVALID_INDEX"; }
        buckets += 1;
    }
    if count != b.active_count || buckets != count || best_bid != b.best_bid || best_ask != b.best_ask || best_bid >= best_ask ||
       (b.mode == "CLOSED" && count > 0) { return "INVALID_BOOK"; }
    if reserved_yes != b.reserved_yes || reserved_no != b.reserved_no || reserved_yes > b.pairs || reserved_no > b.pairs { return "INVALID_SUPPLY"; }
    if b.last_price != 0 && (b.last_price < b.policy.min_price || b.last_price > b.policy.max_price || b.last_price % b.policy.tick != 0) { return "INTERNAL_PRICE_OUT_OF_BAND"; }
    return "";
}

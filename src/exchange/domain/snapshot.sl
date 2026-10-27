import "encoding";

pub gc struct Snapshot {
    policy: Policy, orders: [Order], mode: str, last_seq: int, state_hash: str, last_price: opt[int], pairs: int, collateral: int,
}

pub fn digest_text(data: wire, offset: int) -> str {
    let text = byte_writer(64); write_hex(&mut text, data, offset, 32); return to_str(to_bytes(text.data));
}

pub fn snapshot(b: &Book) -> Snapshot {
    let orders: [Order] = [];
    for side in 0..2 {
        for price in b.policy.min_price..(b.policy.max_price + 1) {
            let slot = level_of(b, side == 0, price).head;
            while slot >= 0 { push(orders, b.slots[slot].order); slot = b.slots[slot].next; }
        }
    }
    let last: opt[int] = none; if b.last_price != 0 { last = some(b.last_price); }
    return Snapshot { policy: b.policy, orders: orders, mode: b.mode, last_seq: b.last_seq,
        state_hash: digest_text(b.digest.data, 0), last_price: last, pairs: b.pairs, collateral: b.collateral };
}

fn order_before(p: Policy, a: Order, b: Order) -> bool {
    if is_bid(a) != is_bid(b) { return is_bid(a); }
    let ap = yes_price(p, a); let bp = yes_price(p, b);
    if ap != bp { return ap < bp; }
    if a.accepted_seq != b.accepted_seq { return a.accepted_seq < b.accepted_seq; }
    return a.id < b.id;
}

pub fn restore(s: Snapshot, capacity: int) -> result[Book, str] {
    if len(s.orders) > capacity || s.last_seq < 0 || len(s.state_hash) != 64 { return err("INVALID_SNAPSHOT"); }
    let decoded = encoding.hex_decode(s.state_hash); guard let digest = decoded else { return err("INVALID_SNAPSHOT"); }
    if len(digest) != 32 || encoding.hex_encode(digest) != s.state_hash { return err("INVALID_SNAPSHOT"); }
    let created = new_book(s.policy, capacity, s.pairs); guard let b = created else let e = err_of(created) { return err(e); }
    if s.collateral != b.collateral { return err("INVALID_SUPPLY"); }
    let orders: [Order] = []; let scratch_orders: [Order] = [];
    for o in s.orders { push(orders, o); push(scratch_orders, empty_order()); }
    let width = 1;
    while width < len(orders) {
        let start = 0;
        while start < len(orders) {
            let middle = start + width; if middle > len(orders) { middle = len(orders); }
            let end = middle + width; if end > len(orders) { end = len(orders); }
            let i = start; let j = middle;
            for out in start..end {
                if i < middle && (j >= end || order_before(s.policy, orders[i], orders[j])) { scratch_orders[out] = orders[i]; i += 1; }
                else { scratch_orders[out] = orders[j]; j += 1; }
            }
            start = end;
        }
        for i in 0..len(orders) { orders[i] = scratch_orders[i]; }
        width *= 2;
    }
    let scratch = byte_writer(36);
    for o in orders {
        if !valid_order_state(s.policy, o, scratch.data) || o.remaining < 1 || o.accepted_seq > s.last_seq || o.tif != "GTC" ||
           find_order(&b, o.id, scratch.data) >= 0 { return err("INVALID_SNAPSHOT_ORDER"); }
        let price = yes_price(s.policy, o); let bid = is_bid(o);
        guard let total = add_units(level_of(&b, bid, price).total, o.remaining) else { return err("OVERFLOW"); }
        if total < 1 { return err("INVALID_LEVEL"); }
        if o.side == "SELL" {
            let value = b.reserved_yes; if o.outcome == "NO" { value = b.reserved_no; }
            guard let next = add_units(value, o.remaining) else { return err("OVERFLOW"); }
            if next > b.pairs { return err("INVALID_SUPPLY"); }
            if o.outcome == "YES" { b.reserved_yes = next; } else { b.reserved_no = next; }
        }
        b.free_count -= 1; let slot = b.free_slots[b.free_count];
        insert_slot(&mut b, slot, o, scratch.data);
        if bid && price > b.best_bid { b.best_bid = price; }
        if !bid && price < b.best_ask { b.best_ask = price; }
    }
    b.mode = s.mode; b.last_seq = s.last_seq; b.last_price = s.last_price ?? 0;
    for i in 0..32 { b.digest.data[i] = digest[i] as int; }
    let w = new_workspace(&b, 1);
    let error = verify(&b, &mut w);
    if error != "" { return err(error); }
    return ok(b);
}

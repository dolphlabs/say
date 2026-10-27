pub struct Book {
    policy: Policy, mode: str, last_seq: int, last_price: int, pairs: int, collateral: int,
    reserved_yes: int, reserved_no: int, active_count: int, best_bid: int, best_ask: int,
    bids: [Level], asks: [Level], slots: [Slot], index: [Bucket], free_slots: [int], free_count: int,
    digest: ByteWriter,
    yes_asset: str, no_asset: str, collateral_owner: str, shares_owner: str,
}

pub fn new_book(policy: Policy, capacity: int, pairs: int) -> result[Book, str] {
    let scratch = byte_writer(36);
    if !valid_policy(policy, scratch.data) || capacity < 1 || capacity > 100000 { return err("INVALID_POLICY"); }
    guard let collateral = mul_units(policy.V, pairs) else { return err("INVALID_SUPPLY"); }
    let bids: [Level] = []; let asks: [Level] = []; let slots: [Slot] = [];
    let index: [Bucket] = []; let free_slots: [int] = [];
    for i in 0..(policy.V + 1) {
        push(bids, Level { head: -1, tail: -1, total: 0 });
        push(asks, Level { head: -1, tail: -1, total: 0 });
    }
    for i in 0..capacity {
        push(slots, Slot { order: empty_order(), previous: -1, next: -1, generation: 0, active: false });
        push(free_slots, capacity - i - 1);
    }
    let buckets = 2;
    while buckets < capacity * 2 { buckets *= 2; }
    for i in 0..buckets { push(index, Bucket { slot: -1, home: 0 }); }
    let book = Book { policy: policy, mode: "OPEN", last_seq: 0, last_price: 0, pairs: pairs, collateral: collateral,
        reserved_yes: 0, reserved_no: 0, active_count: 0, best_bid: 0, best_ask: policy.V,
        bids: bids, asks: asks, slots: slots, index: index, free_slots: free_slots, free_count: capacity,
        digest: byte_writer(32), yes_asset: "YES:" + policy.market_id, no_asset: "NO:" + policy.market_id,
        collateral_owner: "system:collateral:" + policy.market_id, shares_owner: "system:shares:" + policy.market_id };
    genesis(&mut book);
    return ok(book);
}

fn id_home(id: str, capacity: int, scratch: wire) -> int {
    wire_put(scratch, 0, id);
    let h = 0;
    for i in 0..36 { h = (h * 257 + scratch[i]) & (capacity - 1); }
    return h;
}

pub fn find_order(b: &Book, id: str, scratch: wire) -> int {
    if len(id) != 36 { return -1; }
    let at = id_home(id, len(b.index), scratch);
    for i in 0..len(b.index) {
        let slot = b.index[at].slot;
        if slot < 0 { return -1; }
        if b.slots[slot].order.id == id { return slot; }
        at = (at + 1) & (len(b.index) - 1);
    }
    return -1;
}

fn index_insert(b: &mut Book, slot: int, scratch: wire) {
    let home = id_home(b.slots[slot].order.id, len(b.index), scratch);
    let at = home;
    while b.index[at].slot >= 0 { at = (at + 1) & (len(b.index) - 1); }
    b.index[at] = Bucket { slot: slot, home: home };
}

fn index_remove(b: &mut Book, id: str, scratch: wire) {
    let mask = len(b.index) - 1;
    let hole = id_home(id, len(b.index), scratch);
    while b.index[hole].slot >= 0 && b.slots[b.index[hole].slot].order.id != id { hole = (hole + 1) & mask; }
    assert(b.index[hole].slot >= 0);
    let at = (hole + 1) & mask;
    while b.index[at].slot >= 0 {
        let bucket = b.index[at];
        if ((at - bucket.home) & mask) > ((hole - bucket.home) & mask) {
            b.index[hole] = bucket;
            hole = at;
        }
        at = (at + 1) & mask;
    }
    b.index[hole] = Bucket { slot: -1, home: 0 };
}

fn level_of(b: &Book, bid: bool, price: int) -> Level {
    if bid { return b.bids[price]; }
    return b.asks[price];
}

fn set_level(b: &mut Book, bid: bool, price: int, level: Level) {
    if bid { b.bids[price] = level; } else { b.asks[price] = level; }
}

fn remove_slot(b: &mut Book, at: int, scratch: wire) {
    let slot = b.slots[at];
    let bid = is_bid(slot.order);
    let price = yes_price(b.policy, slot.order);
    let level = level_of(&*b, bid, price);
    if slot.previous >= 0 {
        let previous = b.slots[slot.previous]; previous.next = slot.next; b.slots[slot.previous] = previous;
    } else { level.head = slot.next; }
    if slot.next >= 0 {
        let next = b.slots[slot.next]; next.previous = slot.previous; b.slots[slot.next] = next;
    } else { level.tail = slot.previous; }
    level.total -= slot.order.remaining;
    set_level(&mut *b, bid, price, level);
    index_remove(&mut *b, slot.order.id, scratch);
    slot.active = false; slot.previous = -1; slot.next = -1; slot.order = empty_order();
    b.slots[at] = slot;
    b.free_slots[b.free_count] = at; b.free_count += 1; b.active_count -= 1;
}

fn insert_slot(b: &mut Book, at: int, order: Order, scratch: wire) {
    let bid = is_bid(order); let price = yes_price(b.policy, order);
    let level = level_of(&*b, bid, price);
    if level.tail >= 0 {
        let previous = b.slots[level.tail]; previous.next = at; b.slots[level.tail] = previous;
    } else { level.head = at; }
    b.slots[at] = Slot { order: order, previous: level.tail, next: -1, generation: b.slots[at].generation + 1, active: true };
    level.tail = at; level.total += order.remaining;
    set_level(&mut *b, bid, price, level);
    index_insert(&mut *b, at, scratch);
    b.active_count += 1;
}

fn update_slot(b: &mut Book, at: int, order: Order) {
    let slot = b.slots[at];
    let price = yes_price(b.policy, order); let bid = is_bid(order);
    let level = level_of(&*b, bid, price);
    level.total += order.remaining - slot.order.remaining;
    slot.order = order; b.slots[at] = slot;
    set_level(&mut *b, bid, price, level);
}

fn update_best(b: &mut Book) {
    while b.best_bid > 0 && b.bids[b.best_bid].total == 0 { b.best_bid -= 1; }
    while b.best_ask < b.policy.V && b.asks[b.best_ask].total == 0 { b.best_ask += 1; }
}

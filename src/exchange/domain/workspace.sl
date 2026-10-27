pub struct Transition {
    base_seq: int, seq: int, command_ref: str, command_kind: str, decision: str, mode: str,
    fill_count: int, update_count: int, posting_count: int, entry_count: int, hold_count: int, delta_count: int,
    supply_delta: int, collateral_delta: int, last_price: int, incoming_update: int, rested_slot: int,
    reserved_yes: int, reserved_no: int,
}

fn empty_transition() -> Transition {
    return Transition { base_seq: 0, seq: 0, command_ref: "", command_kind: "", decision: "ACCEPTED", mode: "OPEN",
        fill_count: 0, update_count: 0, posting_count: 0, entry_count: 0, hold_count: 0, delta_count: 0,
        supply_delta: 0, collateral_delta: 0, last_price: 0, incoming_update: -1, rested_slot: -1, reserved_yes: 0, reserved_no: 0 };
}

pub struct Workspace {
    transition: Transition, ready: bool, error: str, epoch: int,
    fills: [Fill], updates: [Update], postings: [Posting], entries: [Entry], holds: [Hold], deltas: [LevelDelta],
    verify_seen: [int], slot_epochs: [int], slot_updates: [int], level_epochs: [int], level_totals: [int],
    keys: ByteWriter, canonical: ByteWriter, hashes: ByteWriter, scratch: ByteWriter, hash: Sha256,
}

pub fn new_workspace(b: &Book, capacity: int) -> Workspace {
    assert(capacity >= 1 && capacity <= 100000);
    let fills: [Fill] = []; let updates: [Update] = []; let postings: [Posting] = [];
    let entries: [Entry] = []; let holds: [Hold] = []; let deltas: [LevelDelta] = [];
    let verify_seen: [int] = []; let slot_epochs: [int] = []; let slot_updates: [int] = []; let level_epochs: [int] = []; let level_totals: [int] = [];
    for i in 0..capacity {
        push(fills, Fill { mode: "", maker_order_id: "", taker_order_id: "", qty: 0, yes_price: 0 });
    }
    for i in 0..(capacity + 1) {
        push(updates, Update { order: empty_order(), slot: -1, generation: 0, fee_charged_now: false, cancel_reason: "", status: "" });
    }
    for i in 0..(3 * capacity + 3) {
        push(postings, Posting { key_start: 0, key_size: 0, kind: "", ref_type: "", ref_id: "", entry_start: 0,
            entry_count: 0, hold_start: 0, hold_count: 0 });
    }
    for i in 0..(13 * capacity + 6) { push(entries, Entry { owner_kind: "", owner_id: "", asset_key: "", bucket: "", delta: 0, hold: "" }); }
    for i in 0..(5 * capacity + 3) { push(holds, Hold { op: "", hold_id: "", owner_kind: "", owner_id: "", asset_key: "", amount: 0 }); }
    for i in 0..len(b.slots) { push(verify_seen, 0); push(slot_epochs, 0); push(slot_updates, -1); }
    for i in 0..(2 * (b.policy.V + 1)) {
        push(level_epochs, 0); push(level_totals, 0);
        push(deltas, LevelDelta { side: "", yes_price: 0, new_level_qty: 0 });
    }
    return Workspace { transition: empty_transition(), ready: false, error: "", epoch: 0,
        fills: fills, updates: updates, postings: postings, entries: entries, holds: holds, deltas: deltas,
        verify_seen: verify_seen, slot_epochs: slot_epochs, slot_updates: slot_updates, level_epochs: level_epochs, level_totals: level_totals,
        keys: byte_writer(240 * capacity + 256), canonical: byte_writer(6000 * capacity + 8192),
        hashes: byte_writer(128), scratch: byte_writer(36), hash: sha256_workspace() };
}

fn start_plan(b: &Book, cmd: Command, w: &mut Workspace) {
    w.ready = false; w.error = "";
    w.transition = empty_transition();
    w.transition.base_seq = b.last_seq; w.transition.seq = cmd.seq; w.transition.command_ref = cmd.ref;
    w.transition.command_kind = cmd.kind; w.transition.mode = b.mode;
    w.transition.reserved_yes = b.reserved_yes; w.transition.reserved_no = b.reserved_no;
    if w.epoch == max_units() {
        for i in 0..len(w.slot_epochs) { w.slot_epochs[i] = 0; }
        for i in 0..len(w.level_epochs) { w.level_epochs[i] = 0; }
        w.epoch = 0;
    }
    w.epoch += 1;
    reset_writer(&mut w.keys); reset_writer(&mut w.canonical);
    for i in 0..32 { w.hashes.data[i] = b.digest.data[i]; }
}

fn fail(w: &mut Workspace, error: str) {
    if w.error == "" { w.error = error; }
    w.ready = false;
}

fn touch(b: &Book, slot: int, w: &mut Workspace) -> int {
    if slot >= 0 && w.slot_epochs[slot] == w.epoch { return w.slot_updates[slot]; }
    if w.transition.update_count == len(w.updates) { fail(&mut *w, "NEED_CAPACITY"); return -1; }
    let at = w.transition.update_count;
    w.transition.update_count += 1;
    if slot >= 0 {
        w.updates[at] = Update { order: b.slots[slot].order, slot: slot, generation: b.slots[slot].generation,
            fee_charged_now: false, cancel_reason: "", status: "" };
        w.slot_epochs[slot] = w.epoch; w.slot_updates[slot] = at;
    }
    return at;
}

fn touch_incoming(b: &Book, order: Order, w: &mut Workspace) -> int {
    if w.transition.incoming_update >= 0 { return w.transition.incoming_update; }
    let at = touch(b, -1, &mut *w);
    if at >= 0 {
        w.updates[at] = Update { order: order, slot: -1, generation: 0, fee_charged_now: false, cancel_reason: "", status: "" };
        w.transition.incoming_update = at;
    }
    return at;
}

fn level_change(b: &Book, bid: bool, price: int, delta: int, w: &mut Workspace) {
    let at = price;
    if !bid { at += b.policy.V + 1; }
    if w.level_epochs[at] != w.epoch {
        w.level_epochs[at] = w.epoch;
        w.level_totals[at] = level_of(b, bid, price).total;
    }
    guard let total = add_units(w.level_totals[at], delta) else { fail(&mut *w, "OVERFLOW"); return; }
    if total < 0 { fail(&mut *w, "INVALID_LEVEL"); return; }
    w.level_totals[at] = total;
}

fn add_entry(w: &mut Workspace, kind: str, owner: str, asset: str, delta: int, hold: str) {
    if w.error != "" { return; }
    if delta == 0 { fail(&mut *w, "ZERO_ENTRY"); return; }
    let at = w.transition.entry_count;
    if at == len(w.entries) { fail(&mut *w, "NEED_CAPACITY"); return; }
    let bucket = "free"; if hold != "" { bucket = "held"; }
    w.entries[at] = Entry { owner_kind: kind, owner_id: owner, asset_key: asset, bucket: bucket, delta: delta, hold: hold };
    w.transition.entry_count += 1;
}

fn add_hold(w: &mut Workspace, op: str, order: Order, asset: str, amount: int, hold: str) {
    if w.error != "" { return; }
    let at = w.transition.hold_count;
    if at == len(w.holds) { fail(&mut *w, "NEED_CAPACITY"); return; }
    w.holds[at] = Hold { op: op, hold_id: hold, owner_kind: order.owner_kind, owner_id: order.account_id, asset_key: asset, amount: amount };
    w.transition.hold_count += 1;
}

fn begin_posting(w: &mut Workspace, kind: str, ref_type: str, ref_id: str) -> Posting {
    return Posting { kind: kind, ref_type: ref_type, ref_id: ref_id, key_start: w.keys.position, key_size: 0,
        entry_start: w.transition.entry_count, entry_count: 0, hold_start: w.transition.hold_count, hold_count: 0 };
}

fn end_posting(w: &mut Workspace, posting: Posting) {
    if w.error != "" { return; }
    if w.keys.failed || w.transition.posting_count == len(w.postings) { fail(&mut *w, "NEED_CAPACITY"); return; }
    posting.key_size = w.keys.position - posting.key_start;
    posting.entry_count = w.transition.entry_count - posting.entry_start;
    posting.hold_count = w.transition.hold_count - posting.hold_start;
    w.postings[w.transition.posting_count] = posting;
    w.transition.posting_count += 1;
}

fn workspace_fits(b: &Book, w: &Workspace) -> bool {
    return len(w.slot_epochs) == len(b.slots) && len(w.slot_updates) == len(b.slots) && len(w.verify_seen) == len(b.slots) &&
        len(w.level_epochs) == 2 * (b.policy.V + 1) && len(w.level_totals) == 2 * (b.policy.V + 1) &&
        len(w.deltas) == 2 * (b.policy.V + 1);
}

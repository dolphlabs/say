import "encoding";

pub fn prepare_decided(b: &Book, d: Decided, w: &mut Workspace) -> str {
    w.ready = false;
    if !workspace_fits(b, &*w) { return "WORKSPACE_MISMATCH"; }
    let cmd = Command { kind: d.command_kind, seq: d.seq, ref: d.command_ref, order: empty_order(), order_id: "", account_id: "", system: true, reason: "" };
    start_plan(b, cmd, &mut *w);
    if d.market_id != b.policy.market_id || d.season_id != b.policy.season_id || d.base_seq != b.last_seq ||
       d.prev_hash != digest_text(b.digest.data, 0) || b.last_seq == max_units() || d.seq != b.last_seq + 1 { return "STALE_TRANSITION"; }
    if len(d.fills) > len(w.fills) || len(d.updates) > len(w.updates) || len(d.deltas) > len(w.deltas) ||
       len(d.postings) > len(w.postings) { return "NEED_CAPACITY"; }
    let decoded = encoding.hex_decode(d.state_hash); guard let digest = decoded else { return "TRANSITION_HASH_MISMATCH"; }
    if len(digest) != 32 || encoding.hex_encode(digest) != d.state_hash { return "TRANSITION_HASH_MISMATCH"; }
    w.transition.decision = d.decision; w.transition.mode = d.mode; w.transition.supply_delta = d.supply_delta;
    w.transition.collateral_delta = d.collateral_delta; w.transition.last_price = d.last_price;
    w.transition.fill_count = len(d.fills); w.transition.update_count = len(d.updates); w.transition.delta_count = len(d.deltas);
    for i in 0..len(d.fills) { w.fills[i] = d.fills[i]; }
    for i in 0..len(d.deltas) { w.deltas[i] = d.deltas[i]; }
    let terminal = -1;
    for i in 0..len(d.updates) {
        let u = d.updates[i];
        let slot = find_order(b, u.order.id, w.scratch.data); u.slot = slot; u.generation = 0;
        let before = 0;
        if slot >= 0 {
            if w.slot_epochs[slot] == w.epoch { return "DUPLICATE_ORDER_UPDATE"; }
            u.generation = b.slots[slot].generation; before = b.slots[slot].order.remaining;
            w.slot_epochs[slot] = w.epoch; w.slot_updates[slot] = i;
            if u.order.remaining == 0 { terminal = slot; }
        } else {
            if w.transition.incoming_update >= 0 { return "INVALID_ORDER_FACTS"; }
            w.transition.incoming_update = i;
        }
        if u.order.side == "SELL" {
            let reserved = w.transition.reserved_yes; if u.order.outcome == "NO" { reserved = w.transition.reserved_no; }
            guard let next = add_units(reserved - before, u.order.remaining) else { return "OVERFLOW"; }
            if u.order.outcome == "YES" { w.transition.reserved_yes = next; } else { w.transition.reserved_no = next; }
        }
        w.updates[i] = u;
    }
    let incoming = w.transition.incoming_update;
    if incoming >= 0 && w.updates[incoming].order.remaining > 0 {
        w.transition.rested_slot = terminal;
        if b.free_count > 0 { w.transition.rested_slot = b.free_slots[b.free_count - 1]; }
    }
    for p in d.postings {
        let posting = begin_posting(&mut *w, p.kind, p.ref_type, p.ref_id);
        write_raw(&mut w.keys, p.business_key);
        for e in p.entries { add_entry(&mut *w, e.owner_kind, e.owner_id, e.asset_key, e.delta, e.hold); }
        for h in p.holds {
            if w.transition.hold_count == len(w.holds) { return "NEED_CAPACITY"; }
            w.holds[w.transition.hold_count] = h; w.transition.hold_count += 1;
        }
        end_posting(&mut *w, posting);
    }
    if w.error != "" { return w.error; }
    for i in 0..32 { w.hashes.data[32 + i] = digest[i] as int; }
    w.ready = true;
    let error = validate_apply(b, &mut *w);
    if error != "" { w.ready = false; return error; }
    if let expected = d.full_state_hash {
        let full_error = full_hash(b, true, &mut *w);
        if full_error != "" { w.ready = false; return full_error; }
        if digest_text(w.hashes.data, 64) != expected { w.ready = false; return "SNAPSHOT_HASH_MISMATCH"; }
    }
    return "";
}

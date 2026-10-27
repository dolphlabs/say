fn same_order_identity(a: Order, b: Order) -> bool {
    return a.id == b.id && a.account_id == b.account_id && a.owner_kind == b.owner_kind && a.owner_group == b.owner_group &&
        a.outcome == b.outcome && a.side == b.side && a.limit == b.limit && a.qty == b.qty && a.tif == b.tif &&
        a.accepted_seq == b.accepted_seq && a.sedi_hold_id == b.sedi_hold_id && a.share_hold_id == b.share_hold_id &&
        a.sedi_original == b.sedi_original && a.shares_original == b.shares_original;
}

fn valid_order_state(p: Policy, o: Order, scratch: wire) -> bool {
    if !canonical_uuid(o.id, scratch) || !canonical_uuid(o.account_id, scratch) || !canonical_uuid(o.sedi_hold_id, scratch) ||
       (o.owner_group != "" && !canonical_uuid(o.owner_group, scratch)) { return false; }
    if (o.owner_kind != "user" && o.owner_kind != "bot") || (o.outcome != "YES" && o.outcome != "NO") ||
       (o.side != "BUY" && o.side != "SELL") || (o.tif != "GTC" && o.tif != "IOC") { return false; }
    if o.limit < p.min_price || o.limit > p.max_price || o.limit % p.tick != 0 || o.qty < 1 || o.qty > p.max_order_qty ||
       o.remaining < 0 || o.filled < 0 || o.cancelled < 0 || o.accepted_seq < 1 { return false; }
    if o.remaining > o.qty || o.filled > o.qty - o.remaining || o.cancelled != o.qty - o.remaining - o.filled { return false; }
    if o.fee_paid != (o.filled > 0) { return false; }
    if o.sedi_original < 0 || o.sedi_consumed < 0 || o.sedi_released < 0 || o.sedi_consumed > o.sedi_original ||
       o.sedi_released > o.sedi_original - o.sedi_consumed || o.shares_original < 0 || o.shares_consumed < 0 ||
       o.shares_released < 0 || o.shares_consumed > o.shares_original || o.shares_released > o.shares_original - o.shares_consumed { return false; }
    guard let notional = mul_units(o.qty, o.limit) else { return false; }
    if notional < p.min_order_notional { return false; }
    let original = 1; let target = 0;
    if o.side == "BUY" {
        guard let amount = add_units(notional, 1) else { return false; }
        original = amount;
        target = o.remaining * o.limit;
        if o.shares_original != 0 || o.shares_consumed != 0 || o.shares_released != 0 { return false; }
    } else {
        if !canonical_uuid(o.share_hold_id, scratch) || o.shares_original != o.qty || o.shares_consumed != o.filled ||
           o.shares_original - o.shares_consumed - o.shares_released != o.remaining { return false; }
    }
    if o.remaining > 0 && !o.fee_paid { target += 1; }
    return o.sedi_original == original && o.sedi_original - o.sedi_consumed - o.sedi_released == target;
}

fn validate_apply(b: &Book, w: &mut Workspace) -> str {
    if !workspace_fits(b, &*w) { return "WORKSPACE_MISMATCH"; }
    let t = w.transition;
    if !w.ready { return "NO_PLAN"; }
    if t.base_seq != b.last_seq || b.last_seq == max_units() || t.seq != b.last_seq + 1 { return "STALE_TRANSITION"; }
    for i in 0..32 { if w.hashes.data[i] != b.digest.data[i] { return "STALE_TRANSITION"; } }
    if t.fill_count < 0 || t.fill_count > len(w.fills) || t.update_count < 0 || t.update_count > len(w.updates) ||
       t.posting_count < 0 || t.posting_count > len(w.postings) || t.entry_count < 0 || t.entry_count > len(w.entries) ||
       t.hold_count < 0 || t.hold_count > len(w.holds) || t.delta_count < 0 || t.delta_count > len(w.deltas) { return "INVALID_TRANSITION"; }
    if t.mode != "OPEN" && t.mode != "SUSPENDED" && t.mode != "CLOSED" { return "INVALID_TRANSITION"; }
    if t.last_price != 0 && (t.last_price < b.policy.min_price || t.last_price > b.policy.max_price || t.last_price % b.policy.tick != 0) { return "INTERNAL_PRICE_OUT_OF_BAND"; }
    guard let pairs = add_units(b.pairs, t.supply_delta) else { return "OVERFLOW"; }
    guard let collateral = mul_units(pairs, b.policy.V) else { return "INVALID_SUPPLY"; }
    if collateral - b.collateral != t.collateral_delta { return "INVALID_SUPPLY"; }
    let reserved_yes = b.reserved_yes; let reserved_no = b.reserved_no;
    let terminals = 0; let incoming = -1; let last_terminal = -1;
    for side in 0..2 {
        for price in 0..(b.policy.V + 1) {
            let at = side * (b.policy.V + 1) + price;
            w.level_totals[at] = level_of(b, side == 0, price).total;
        }
    }
    for i in 0..t.update_count {
        let u = w.updates[i]; let o = u.order;
        if !valid_order_state(b.policy, o, w.scratch.data) { return "INVALID_ORDER_FACTS"; }
        let before = 0;
        if u.slot >= 0 {
            if u.slot >= len(b.slots) { return "STALE_SLOT"; }
            let old = b.slots[u.slot];
            if !old.active || old.generation != u.generation || !same_order_identity(old.order, o) ||
               w.slot_epochs[u.slot] != w.epoch || w.slot_updates[u.slot] != i { return "STALE_SLOT"; }
            if o.remaining > old.order.remaining || o.filled < old.order.filled || o.cancelled < old.order.cancelled ||
               o.sedi_consumed < old.order.sedi_consumed || o.sedi_released < old.order.sedi_released ||
               o.shares_consumed < old.order.shares_consumed || o.shares_released < old.order.shares_released { return "INVALID_ORDER_FACTS"; }
            before = old.order.remaining;
            if o.remaining == 0 { terminals += 1; last_terminal = u.slot; }
        } else {
            if incoming >= 0 || (t.command_kind != "Place" && t.command_kind != "RejectPlace") || o.accepted_seq != t.seq || find_order(b, o.id, w.scratch.data) >= 0 { return "INVALID_ORDER_FACTS"; }
            incoming = i;
        }
        let at = yes_price(b.policy, o); if !is_bid(o) { at += b.policy.V + 1; }
        guard let total = add_units(w.level_totals[at] - before, o.remaining) else { return "OVERFLOW"; }
        if total < 0 { return "INVALID_LEVEL"; }
        w.level_totals[at] = total;
        if o.side == "SELL" {
            if o.outcome == "YES" {
                guard let amount = add_units(reserved_yes - before, o.remaining) else { return "OVERFLOW"; }
                reserved_yes = amount;
            } else {
                guard let amount = add_units(reserved_no - before, o.remaining) else { return "OVERFLOW"; }
                reserved_no = amount;
            }
        }
    }
    if reserved_yes < 0 || reserved_no < 0 || reserved_yes > pairs || reserved_no > pairs ||
       reserved_yes != t.reserved_yes || reserved_no != t.reserved_no || incoming != t.incoming_update { return "INVALID_SUPPLY"; }
    if t.command_kind == "RejectPlace" {
        if incoming < 0 || t.update_count != 1 || t.fill_count != 0 || t.supply_delta != 0 || t.collateral_delta != 0 ||
           t.delta_count != 0 || t.mode != b.mode || !rejection_reason(t.decision) { return "INVALID_REJECTION"; }
        let u = w.updates[incoming];
        if u.order.filled != 0 || u.order.remaining != 0 || u.order.cancelled != u.order.qty || u.fee_charged_now ||
           u.cancel_reason != t.decision || u.status != "CANCELLED" { return "INVALID_REJECTION"; }
    }
    if t.fill_count > 0 && incoming < 0 { return "INVALID_FILL"; }
    if t.mode == "CLOSED" && b.active_count - terminals > 0 { return "INVALID_TRANSITION"; }
    for i in 0..t.fill_count {
        let f = w.fills[i]; let taker = w.updates[incoming].order;
        let maker_slot = find_order(b, f.maker_order_id, w.scratch.data);
        if maker_slot < 0 || w.slot_epochs[maker_slot] != w.epoch || f.taker_order_id != taker.id || f.qty <= 0 ||
           f.yes_price < b.policy.min_price || f.yes_price > b.policy.max_price || f.yes_price % b.policy.tick != 0 { return "INVALID_FILL"; }
        let maker = b.slots[maker_slot].order;
        if maker.account_id == taker.account_id || (maker.owner_group != "" && maker.owner_group == taker.owner_group) ||
           yes_price(b.policy, maker) != f.yes_price || is_bid(maker) == is_bid(taker) { return "INVALID_FILL"; }
        let own_price = f.yes_price; if taker.outcome == "NO" { own_price = b.policy.V - own_price; }
        if (taker.side == "BUY" && own_price > taker.limit) || (taker.side == "SELL" && own_price < taker.limit) { return "INVALID_FILL"; }
        let bid = maker; let ask = taker; if is_bid(taker) { bid = taker; ask = maker; }
        let mode = "MERGE";
        if bid.side == "BUY" && ask.side == "SELL" { mode = "TRANSFER_YES"; }
        if bid.side == "SELL" && ask.side == "BUY" { mode = "TRANSFER_NO"; }
        if bid.side == "BUY" && ask.side == "BUY" { mode = "MINT"; }
        if f.mode != mode { return "INVALID_FILL"; }
    }
    let resting = incoming >= 0;
    if resting { resting = w.updates[incoming].order.remaining > 0; }
    if resting {
        let slot = last_terminal;
        if b.free_count > 0 { slot = b.free_slots[b.free_count - 1]; }
        if slot < 0 || slot != t.rested_slot || b.slots[slot].generation == max_units() { return "NEED_CAPACITY"; }
        let order = w.updates[incoming].order;
        if order.tif != "GTC" || t.mode != "OPEN" { return "INVALID_ORDER_FACTS"; }
    } else if t.rested_slot != -1 { return "INVALID_TRANSITION"; }
    let delta_index = 0;
    for side in 0..2 {
        for price in b.policy.min_price..(b.policy.max_price + 1) {
            let total = w.level_totals[side * (b.policy.V + 1) + price];
            if total == level_of(b, side == 0, price).total { continue; }
            if delta_index >= t.delta_count { return "INVALID_LEVEL"; }
            let delta = w.deltas[delta_index]; let name = "bid"; if side == 1 { name = "ask"; }
            if delta.side != name || delta.yes_price != price || delta.new_level_qty != total { return "INVALID_LEVEL"; }
            delta_index += 1;
        }
    }
    if delta_index != t.delta_count { return "INVALID_LEVEL"; }
    for i in 0..t.posting_count {
        let p = w.postings[i];
        if p.key_start < 0 || p.key_size < 1 || p.key_start > w.keys.position || p.key_size > w.keys.position - p.key_start ||
           p.entry_start < 0 || p.entry_count < 1 || p.entry_start > t.entry_count || p.entry_count > t.entry_count - p.entry_start ||
           p.hold_start < 0 || p.hold_count < 0 || p.hold_start > t.hold_count || p.hold_count > t.hold_count - p.hold_start { return "INVALID_POSTING"; }
        let sedi = 0; let yes = 0; let no = 0;
        for j in p.entry_start..(p.entry_start + p.entry_count) {
            let e = w.entries[j];
            if e.delta == 0 { return "ZERO_ENTRY"; }
            let value = sedi;
            if e.asset_key == b.yes_asset { value = yes; }
            else if e.asset_key == b.no_asset { value = no; }
            else if e.asset_key != "SEDI" { return "INVALID_ASSET"; }
            guard let next = add_units(value, e.delta) else { return "OVERFLOW"; }
            if e.asset_key == "SEDI" { sedi = next; } else if e.asset_key == b.yes_asset { yes = next; } else { no = next; }
        }
        if sedi != 0 || yes != 0 || no != 0 { return "UNBALANCED_POSTING"; }
    }
    encode_transition(b, &mut *w);
    if w.canonical.failed { return "NEED_CAPACITY"; }
    if !sha256_into(&mut w.hash, w.canonical.data, w.canonical.position, w.hashes.data, 96) { return "HASH_CAPACITY"; }
    for i in 0..32 { if w.hashes.data[32 + i] != w.hashes.data[96 + i] { return "TRANSITION_HASH_MISMATCH"; } }
    return "";
}

pub fn apply(b: &mut Book, w: &mut Workspace) -> str {
    let error = validate_apply(&*b, &mut *w);
    if error != "" { return error; }
    let t = w.transition;
    let reserve_free = t.rested_slot >= 0 && b.free_count > 0;
    if reserve_free { b.free_count -= 1; }
    for i in 0..t.update_count {
        let u = w.updates[i];
        if u.slot < 0 { continue; }
        if u.order.remaining == 0 { remove_slot(&mut *b, u.slot, w.scratch.data); }
        else { update_slot(&mut *b, u.slot, u.order); }
    }
    if t.rested_slot >= 0 {
        if !reserve_free { b.free_count -= 1; assert(b.free_slots[b.free_count] == t.rested_slot); }
        let order = w.updates[t.incoming_update].order;
        insert_slot(&mut *b, t.rested_slot, order, w.scratch.data);
        let price = yes_price(b.policy, order);
        if is_bid(order) && price > b.best_bid { b.best_bid = price; }
        if !is_bid(order) && price < b.best_ask { b.best_ask = price; }
    }
    update_best(&mut *b);
    b.pairs += t.supply_delta; b.collateral += t.collateral_delta;
    b.reserved_yes = t.reserved_yes; b.reserved_no = t.reserved_no;
    b.mode = t.mode; b.last_seq = t.seq;
    if t.last_price != 0 { b.last_price = t.last_price; }
    for i in 0..32 { b.digest.data[i] = w.hashes.data[32 + i]; }
    w.ready = false;
    return "";
}

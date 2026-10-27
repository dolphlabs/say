fn write_order(w: &mut ByteWriter, o: Order) {
    write_text(&mut *w, o.id);
    write_text(&mut *w, o.account_id);
    write_text(&mut *w, o.owner_kind);
    write_text(&mut *w, o.owner_group);
    write_text(&mut *w, o.outcome);
    write_text(&mut *w, o.side);
    write_int(&mut *w, o.limit);
    write_int(&mut *w, o.qty);
    write_int(&mut *w, o.remaining);
    write_text(&mut *w, o.tif);
    write_int(&mut *w, o.accepted_seq);
    write_bool(&mut *w, o.fee_paid);
    write_text(&mut *w, o.sedi_hold_id);
    write_text(&mut *w, o.share_hold_id);
    write_int(&mut *w, o.sedi_original);
    write_int(&mut *w, o.sedi_consumed);
    write_int(&mut *w, o.sedi_released);
    write_int(&mut *w, o.shares_original);
    write_int(&mut *w, o.shares_consumed);
    write_int(&mut *w, o.shares_released);
    write_int(&mut *w, o.filled);
    write_int(&mut *w, o.cancelled);
}

fn write_policy(w: &mut ByteWriter, p: Policy) {
    write_text(&mut *w, p.market_id); write_text(&mut *w, p.season_id);
    write_int(&mut *w, p.V); write_int(&mut *w, p.min_price); write_int(&mut *w, p.max_price);
    write_int(&mut *w, p.tick); write_int(&mut *w, p.max_order_qty); write_int(&mut *w, p.min_order_notional);
}

fn encode_transition(b: &Book, w: &mut Workspace) {
    reset_writer(&mut w.canonical);
    write_span(&mut w.canonical, w.hashes.data, 0, 32);
    write_text(&mut w.canonical, "say.transition.v1");
    write_text(&mut w.canonical, b.policy.market_id); write_text(&mut w.canonical, b.policy.season_id);
    write_int(&mut w.canonical, w.transition.base_seq); write_int(&mut w.canonical, w.transition.seq);
    write_text(&mut w.canonical, w.transition.command_ref); write_text(&mut w.canonical, w.transition.command_kind);
    write_text(&mut w.canonical, w.transition.decision); write_text(&mut w.canonical, w.transition.mode);
    write_int(&mut w.canonical, w.transition.fill_count);
    for i in 0..w.transition.fill_count {
        let f = w.fills[i];
        write_int(&mut w.canonical, i); write_text(&mut w.canonical, f.mode);
        write_text(&mut w.canonical, f.maker_order_id); write_text(&mut w.canonical, f.taker_order_id);
        write_int(&mut w.canonical, f.qty); write_int(&mut w.canonical, f.yes_price);
    }
    write_int(&mut w.canonical, w.transition.update_count);
    for i in 0..w.transition.update_count {
        let u = w.updates[i]; write_order(&mut w.canonical, u.order);
        write_text(&mut w.canonical, u.status); write_bool(&mut w.canonical, u.fee_charged_now); write_text(&mut w.canonical, u.cancel_reason);
    }
    write_bool(&mut w.canonical, w.transition.rested_slot >= 0);
    if w.transition.rested_slot >= 0 { write_order(&mut w.canonical, w.updates[w.transition.incoming_update].order); }
    write_int(&mut w.canonical, w.transition.posting_count);
    for i in 0..w.transition.posting_count {
        let p = w.postings[i];
        write_decimal(&mut w.canonical, p.key_size); write_byte(&mut w.canonical, 58);
        write_span(&mut w.canonical, w.keys.data, p.key_start, p.key_size);
        write_text(&mut w.canonical, p.kind); write_text(&mut w.canonical, b.policy.season_id); write_text(&mut w.canonical, b.policy.market_id);
        write_text(&mut w.canonical, p.ref_type); write_text(&mut w.canonical, p.ref_id);
        write_int(&mut w.canonical, p.entry_count);
        for j in p.entry_start..(p.entry_start + p.entry_count) {
            let e = w.entries[j];
            write_text(&mut w.canonical, e.owner_kind); write_text(&mut w.canonical, e.owner_id); write_text(&mut w.canonical, e.asset_key);
            write_text(&mut w.canonical, e.bucket); write_int(&mut w.canonical, e.delta); write_text(&mut w.canonical, e.hold);
        }
        write_int(&mut w.canonical, p.hold_count);
        for j in p.hold_start..(p.hold_start + p.hold_count) {
            let h = w.holds[j];
            write_text(&mut w.canonical, h.op); write_text(&mut w.canonical, h.hold_id);
            write_text(&mut w.canonical, h.owner_kind); write_text(&mut w.canonical, h.owner_id);
            write_text(&mut w.canonical, h.asset_key); write_int(&mut w.canonical, h.amount);
        }
    }
    write_int(&mut w.canonical, w.transition.supply_delta); write_int(&mut w.canonical, w.transition.supply_delta);
    write_int(&mut w.canonical, w.transition.collateral_delta);
    write_int(&mut w.canonical, w.transition.delta_count);
    for i in 0..w.transition.delta_count {
        let d = w.deltas[i]; write_text(&mut w.canonical, d.side); write_int(&mut w.canonical, d.yes_price); write_int(&mut w.canonical, d.new_level_qty);
    }
    write_int(&mut w.canonical, w.transition.fill_count);
    for i in 0..w.transition.fill_count {
        let f = w.fills[i]; write_int(&mut w.canonical, i); write_int(&mut w.canonical, f.yes_price); write_int(&mut w.canonical, f.qty);
        let incoming = w.updates[w.transition.incoming_update].order;
        write_text(&mut w.canonical, book_side(incoming));
    }
    write_bool(&mut w.canonical, w.transition.last_price != 0);
    if w.transition.last_price != 0 { write_int(&mut w.canonical, w.transition.last_price); }
}

fn seal_transition(b: &Book, w: &mut Workspace) {
    encode_transition(b, &mut *w);
    if w.canonical.failed { fail(&mut *w, "NEED_CAPACITY"); return; }
    if !sha256_into(&mut w.hash, w.canonical.data, w.canonical.position, w.hashes.data, 32) { fail(&mut *w, "HASH_CAPACITY"); }
}

pub fn full_hash(b: &Book, projected: bool, w: &mut Workspace) -> str {
    if !workspace_fits(b, &*w) { return "WORKSPACE_MISMATCH"; }
    if projected && !w.ready { return "NO_PLAN"; }
    reset_writer(&mut w.canonical);
    write_text(&mut w.canonical, "say.book.v1"); write_policy(&mut w.canonical, b.policy);
    let mode = b.mode; let seq = b.last_seq; let hash_offset = 0;
    let pairs = b.pairs; let collateral = b.collateral; let last_price = b.last_price; let count = b.active_count;
    if projected {
        mode = w.transition.mode; seq = w.transition.seq; hash_offset = 32;
        pairs += w.transition.supply_delta; collateral += w.transition.collateral_delta;
        if w.transition.last_price != 0 { last_price = w.transition.last_price; }
        for i in 0..w.transition.update_count {
            let u = w.updates[i];
            if u.slot >= 0 && u.order.remaining == 0 { count -= 1; }
            if u.slot < 0 && u.order.remaining > 0 { count += 1; }
        }
    } else { for i in 0..32 { w.hashes.data[i] = b.digest.data[i]; } }
    write_text(&mut w.canonical, mode); write_int(&mut w.canonical, seq);
    write_raw(&mut w.canonical, "64:"); write_hex(&mut w.canonical, w.hashes.data, hash_offset, 32);
    write_int(&mut w.canonical, pairs); write_int(&mut w.canonical, collateral); write_bool(&mut w.canonical, last_price != 0);
    if last_price != 0 { write_int(&mut w.canonical, last_price); }
    write_int(&mut w.canonical, count);
    for side in 0..2 {
        for price in b.policy.min_price..(b.policy.max_price + 1) {
            let slot = level_of(b, side == 0, price).head;
            while slot >= 0 {
                let order = b.slots[slot].order;
                if projected && w.slot_epochs[slot] == w.epoch { order = w.updates[w.slot_updates[slot]].order; }
                if order.remaining > 0 { write_order(&mut w.canonical, order); }
                slot = b.slots[slot].next;
            }
            if projected && w.transition.rested_slot >= 0 {
                let incoming = w.updates[w.transition.incoming_update].order;
                if (side == 0) == is_bid(incoming) && price == yes_price(b.policy, incoming) { write_order(&mut w.canonical, incoming); }
            }
        }
    }
    if w.canonical.failed { return "NEED_CAPACITY"; }
    if !sha256_into(&mut w.hash, w.canonical.data, w.canonical.position, w.hashes.data, 64) { return "HASH_CAPACITY"; }
    return "";
}

fn genesis(b: &mut Book) {
    let buffer = byte_writer(512); let hash = sha256_workspace();
    write_text(&mut buffer, "say.genesis.v1"); write_policy(&mut buffer, b.policy);
    write_int(&mut buffer, b.pairs); write_int(&mut buffer, b.collateral);
    assert(!buffer.failed && sha256_into(&mut hash, buffer.data, buffer.position, b.digest.data, 0));
}

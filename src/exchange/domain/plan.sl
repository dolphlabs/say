fn fresh_order(b: &Book, o: Order, seq: int, w: &mut Workspace) -> str {
    if !canonical_uuid(o.id, w.scratch.data) || !canonical_uuid(o.account_id, w.scratch.data) ||
       !canonical_uuid(o.sedi_hold_id, w.scratch.data) { return "INVALID_IDENTIFIER"; }
    if (o.owner_kind != "user" && o.owner_kind != "bot") || (o.owner_group != "" && !canonical_uuid(o.owner_group, w.scratch.data)) { return "INVALID_ORDER_FACTS"; }
    if (o.outcome != "YES" && o.outcome != "NO") || (o.side != "BUY" && o.side != "SELL") || (o.tif != "GTC" && o.tif != "IOC") { return "INVALID_ORDER"; }
    if o.limit < b.policy.min_price || o.limit > b.policy.max_price || o.limit % b.policy.tick != 0 { return "INVALID_PRICE"; }
    if o.qty < 1 || o.qty > b.policy.max_order_qty { return "INVALID_QUANTITY"; }
    guard let notional = mul_units(o.limit, o.qty) else { return "OVERFLOW"; }
    if notional < b.policy.min_order_notional { return "INVALID_QUANTITY"; }
    if o.accepted_seq != seq || o.remaining != o.qty || o.fee_paid || o.filled != 0 || o.cancelled != 0 ||
       o.sedi_consumed != 0 || o.sedi_released != 0 || o.shares_consumed != 0 || o.shares_released != 0 { return "INVALID_ORDER_FACTS"; }
    let expected = 1;
    if o.side == "BUY" {
        guard let amount = add_units(notional, 1) else { return "OVERFLOW"; }
        expected = amount;
    }
    if o.sedi_original != expected || (o.side == "BUY" && o.shares_original != 0) ||
       (o.side == "SELL" && o.shares_original != o.qty) { return "INVALID_HOLD_FACTS"; }
    if o.side == "SELL" {
        let reserved = b.reserved_yes; if o.outcome == "NO" { reserved = b.reserved_no; }
        if !canonical_uuid(o.share_hold_id, w.scratch.data) || o.qty > b.pairs - reserved { return "INVALID_SUPPLY"; }
    }
    if find_order(b, o.id, w.scratch.data) >= 0 { return "DUPLICATE_ORDER"; }
    return "";
}

fn cancel_update(b: &Book, at: int, reason: str, w: &mut Workspace) {
    if at < 0 || w.error != "" { return; }
    let u = w.updates[at]; let o = u.order;
    if u.slot >= 0 { level_change(b, is_bid(o), yes_price(b.policy, o), 0 - o.remaining, &mut *w); }
    o.cancelled += o.remaining; o.remaining = 0; u.order = o; u.cancel_reason = reason; w.updates[at] = u;
}

fn match_order(b: &Book, order: Order, w: &mut Workspace) {
    let incoming = -1;
    let remaining = order.remaining;
    let bid = is_bid(order); let limit = yes_price(b.policy, order);
    let price = b.best_ask; let step = 1;
    if !bid { price = b.best_bid; step = -1; }
    while remaining > 0 && price > 0 && price < b.policy.V {
        if (bid && price > limit) || (!bid && price < limit) { break; }
        let level = level_of(b, !bid, price);
        let slot = level.head;
        while slot >= 0 && remaining > 0 {
            let maker = b.slots[slot].order;
            if maker.account_id == order.account_id || (maker.owner_group != "" && maker.owner_group == order.owner_group) {
                incoming = touch_incoming(b, order, &mut *w);
                cancel_update(b, incoming, "SELF_TRADE_PREVENTED", &mut *w);
                return;
            }
            if price < b.policy.min_price || price > b.policy.max_price || price % b.policy.tick != 0 || yes_price(b.policy, maker) != price {
                fail(&mut *w, "INTERNAL_PRICE_OUT_OF_BAND"); return;
            }
            let maker_at = touch(b, slot, &mut *w);
            incoming = touch_incoming(b, order, &mut *w);
            if maker_at < 0 || incoming < 0 { return; }
            let qty = remaining; if maker.remaining < qty { qty = maker.remaining; }
            fill_principal(b, maker_at, incoming, price, qty, &mut *w);
            if w.error != "" { return; }
            remaining = w.updates[incoming].order.remaining;
            slot = b.slots[slot].next;
        }
        price += step;
    }
    incoming = touch_incoming(b, order, &mut *w);
    if incoming < 0 { return; }
    if remaining > 0 && order.tif == "IOC" { cancel_update(b, incoming, "IOC_REMAINDER", &mut *w); }
    let rest = w.updates[incoming].order;
    if rest.remaining > 0 { level_change(b, bid, limit, rest.remaining, &mut *w); }
}

fn cancel_command(b: &Book, cmd: Command, w: &mut Workspace) {
    if cmd.kind == "Cancel" {
        let slot = find_order(b, cmd.order_id, w.scratch.data);
        if slot < 0 { w.transition.decision = "ORDER_NOT_OPEN"; return; }
        if !cmd.system && b.slots[slot].order.account_id != cmd.account_id { w.transition.decision = "FORBIDDEN"; return; }
        let at = touch(b, slot, &mut *w);
        cancel_update(b, at, cmd.reason, &mut *w);
        return;
    }
    let reason = cmd.reason; if cmd.kind == "Close" { reason = "MARKET_CLOSED"; }
    for side in 0..2 {
        let bid = side == 0;
        for price in b.policy.min_price..(b.policy.max_price + 1) {
            let slot = level_of(b, bid, price).head;
            while slot >= 0 {
                let o = b.slots[slot].order;
                if cmd.kind == "Close" || o.account_id == cmd.account_id {
                    let at = touch(b, slot, &mut *w);
                    cancel_update(b, at, reason, &mut *w);
                    if w.error != "" { return; }
                }
                slot = b.slots[slot].next;
            }
        }
    }
    if cmd.kind == "Close" { w.transition.mode = "CLOSED"; }
}

fn finalize_plan(b: &Book, w: &mut Workspace) {
    fee_postings(&mut *w);
    release_postings(b, &mut *w);
    if w.error != "" { return; }
    let last_terminal = -1;
    for i in 0..w.transition.update_count {
        let u = w.updates[i]; let o = u.order;
        let before = 0;
        if u.slot >= 0 {
            before = b.slots[u.slot].order.remaining;
            if o.remaining == 0 { last_terminal = u.slot; }
        }
        if o.side == "SELL" {
            let reserved = w.transition.reserved_yes;
            if o.outcome == "NO" { reserved = w.transition.reserved_no; }
            guard let next = add_units(reserved - before, o.remaining) else { fail(&mut *w, "OVERFLOW"); return; }
            if next < 0 { fail(&mut *w, "INVALID_SUPPLY"); return; }
            if o.outcome == "YES" { w.transition.reserved_yes = next; } else { w.transition.reserved_no = next; }
        }
    }
    let pairs = b.pairs + w.transition.supply_delta;
    if w.transition.reserved_yes > pairs || w.transition.reserved_no > pairs { fail(&mut *w, "INVALID_SUPPLY"); return; }
    let incoming = w.transition.incoming_update;
    if incoming >= 0 && w.updates[incoming].order.remaining > 0 {
        let slot = last_terminal;
        if b.free_count > 0 { slot = b.free_slots[b.free_count - 1]; }
        if slot < 0 { fail(&mut *w, "NEED_CAPACITY"); return; }
        if b.slots[slot].generation == max_units() { fail(&mut *w, "GENERATION_EXHAUSTED"); return; }
        w.transition.rested_slot = slot;
    }
    for side in 0..2 {
        let bid = side == 0;
        for price in b.policy.min_price..(b.policy.max_price + 1) {
            let at = price; if !bid { at += b.policy.V + 1; }
            if w.level_epochs[at] != w.epoch { continue; }
            let total = w.level_totals[at];
            if level_of(b, bid, price).total == total { continue; }
            let name = "bid"; if !bid { name = "ask"; }
            w.deltas[w.transition.delta_count] = LevelDelta { side: name, yes_price: price, new_level_qty: total };
            w.transition.delta_count += 1;
        }
    }
}

pub fn plan(b: &Book, cmd: Command, w: &mut Workspace) -> str {
    w.ready = false;
    if !workspace_fits(b, &*w) { return "WORKSPACE_MISMATCH"; }
    start_plan(b, cmd, &mut *w);
    if b.last_seq == max_units() || cmd.seq != b.last_seq + 1 { return "INVALID_SEQUENCE"; }
    if !canonical_uuid(cmd.ref, w.scratch.data) { return "INVALID_COMMAND_REF"; }
    if cmd.kind != "Place" && cmd.kind != "RejectPlace" && cmd.kind != "Cancel" && cmd.kind != "CancelAll" && cmd.kind != "Close" &&
       cmd.kind != "Suspend" && cmd.kind != "Resume" && cmd.kind != "Snapshot" { return "INVALID_COMMAND"; }
    if cmd.kind == "Place" || cmd.kind == "RejectPlace" {
        let error = fresh_order(b, cmd.order, cmd.seq, &mut *w);
        if error != "" { return error; }
    }
    if cmd.kind == "RejectPlace" {
        if !rejection_reason(cmd.reason) { return "INVALID_REJECTION_REASON"; }
        w.transition.decision = cmd.reason;
        let at = touch_incoming(b, cmd.order, &mut *w);
        cancel_update(b, at, cmd.reason, &mut *w);
    } else if b.mode == "CLOSED" && cmd.kind != "Snapshot" {
        w.transition.decision = "MARKET_CLOSED";
        if cmd.kind == "Place" {
            let at = touch_incoming(b, cmd.order, &mut *w);
            cancel_update(b, at, "MARKET_CLOSED", &mut *w);
        }
    } else if cmd.kind == "Place" {
        if b.mode == "SUSPENDED" {
            w.transition.decision = "MARKET_SUSPENDED";
            let at = touch_incoming(b, cmd.order, &mut *w);
            cancel_update(b, at, "MARKET_SUSPENDED", &mut *w);
        } else { match_order(b, cmd.order, &mut *w); }
    } else if cmd.kind == "Cancel" || cmd.kind == "CancelAll" || cmd.kind == "Close" {
        cancel_command(b, cmd, &mut *w);
    } else if cmd.kind == "Suspend" || cmd.kind == "Resume" {
        if cmd.kind == "Suspend" && b.mode == "OPEN" { w.transition.mode = "SUSPENDED"; }
        else if cmd.kind == "Resume" && b.mode == "SUSPENDED" { w.transition.mode = "OPEN"; }
        else { w.transition.decision = "INVALID_TRANSITION"; }
    }
    if w.error == "" { finalize_plan(b, &mut *w); }
    if w.error != "" { return abort_plan(&mut *w); }
    seal_transition(b, &mut *w);
    if w.error != "" { return abort_plan(&mut *w); }
    w.ready = true;
    return "";
}

fn abort_plan(w: &mut Workspace) -> str {
    let error = w.error;
    w.transition = empty_transition();
    w.ready = false;
    reset_writer(&mut w.keys); reset_writer(&mut w.canonical);
    return error;
}

pub fn rejection_reason(reason: str) -> bool {
    return reason == "MARKET_NOT_OPEN" || reason == "MARKET_SUSPENDED" || reason == "MARKET_CLOSED" ||
        reason == "TRADING_HALTED" || reason == "SEASON_NOT_ACTIVE" || reason == "MARKET_DEGRADED" || reason == "ACCOUNT_DISABLED";
}

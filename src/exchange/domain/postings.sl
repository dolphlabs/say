fn order_asset(b: &Book, o: Order) -> str { if o.outcome == "YES" { return b.yes_asset; } return b.no_asset; }

fn take_hold(b: &Book, at: int, share: bool, amount: int, w: &mut Workspace) {
    if w.error != "" { return; }
    let u = w.updates[at]; let o = u.order;
    let hold = o.sedi_hold_id; let asset = "SEDI";
    let available = o.sedi_original - o.sedi_consumed - o.sedi_released;
    if share { hold = o.share_hold_id; asset = order_asset(b, o); available = o.shares_original - o.shares_consumed - o.shares_released; }
    if amount <= 0 || amount > available { fail(&mut *w, "HOLD_EXCEEDED"); return; }
    if share { o.shares_consumed += amount; } else { o.sedi_consumed += amount; }
    u.order = o; w.updates[at] = u;
    add_entry(&mut *w, o.owner_kind, o.account_id, asset, 0 - amount, hold);
    add_hold(&mut *w, "consume", o, asset, amount, hold);
}

fn charge_fee(at: int, w: &mut Workspace) {
    let u = w.updates[at]; let o = u.order;
    if o.fee_paid { return; }
    if o.sedi_original - o.sedi_consumed - o.sedi_released < 1 { fail(&mut *w, "HOLD_EXCEEDED"); return; }
    o.sedi_consumed += 1; o.fee_paid = true;
    u.order = o; u.fee_charged_now = true; w.updates[at] = u;
}

fn fill_principal(b: &Book, maker: int, taker: int, price: int, qty: int, w: &mut Workspace) {
    if w.transition.fill_count == len(w.fills) { fail(&mut *w, "NEED_CAPACITY"); return; }
    let bid = taker; let ask = maker;
    if !is_bid(w.updates[taker].order) { bid = maker; ask = taker; }
    let bo = w.updates[bid].order; let ao = w.updates[ask].order;
    let mode = "MERGE";
    if bo.side == "BUY" && ao.side == "SELL" { mode = "TRANSFER_YES"; }
    if bo.side == "SELL" && ao.side == "BUY" { mode = "TRANSFER_NO"; }
    if bo.side == "BUY" && ao.side == "BUY" { mode = "MINT"; }
    guard let yes_amount = mul_units(price, qty) else { fail(&mut *w, "OVERFLOW"); return; }
    guard let no_amount = mul_units(b.policy.V - price, qty) else { fail(&mut *w, "OVERFLOW"); return; }
    guard let total = add_units(yes_amount, no_amount) else { fail(&mut *w, "OVERFLOW"); return; }
    let kind = mode;
    if mode == "TRANSFER_YES" || mode == "TRANSFER_NO" { kind = "FILL"; }
    let posting = begin_posting(&mut *w, kind, "market_command", w.transition.command_ref);
    write_raw(&mut w.keys, "fill:"); write_raw(&mut w.keys, b.policy.market_id); write_raw(&mut w.keys, ":");
    write_decimal(&mut w.keys, w.transition.seq); write_raw(&mut w.keys, ":"); write_decimal(&mut w.keys, w.transition.fill_count);
    if kind == "FILL" {
        let buyer = bid; let seller = ask; let amount = yes_amount;
        if mode == "TRANSFER_NO" { buyer = ask; seller = bid; amount = no_amount; }
        let buy = w.updates[buyer].order; let sell = w.updates[seller].order;
        let asset = order_asset(b, buy);
        take_hold(b, buyer, false, amount, &mut *w);
        add_entry(&mut *w, sell.owner_kind, sell.account_id, "SEDI", amount, "");
        take_hold(b, seller, true, qty, &mut *w);
        add_entry(&mut *w, buy.owner_kind, buy.account_id, asset, qty, "");
    } else if mode == "MINT" {
        take_hold(b, bid, false, yes_amount, &mut *w);
        take_hold(b, ask, false, no_amount, &mut *w);
        add_entry(&mut *w, "system", b.collateral_owner, "SEDI", total, "");
        add_entry(&mut *w, "system", b.shares_owner, b.yes_asset, 0 - qty, "");
        add_entry(&mut *w, bo.owner_kind, bo.account_id, b.yes_asset, qty, "");
        add_entry(&mut *w, "system", b.shares_owner, b.no_asset, 0 - qty, "");
        add_entry(&mut *w, ao.owner_kind, ao.account_id, b.no_asset, qty, "");
    } else {
        take_hold(b, ask, true, qty, &mut *w);
        add_entry(&mut *w, "system", b.shares_owner, b.yes_asset, qty, "");
        take_hold(b, bid, true, qty, &mut *w);
        add_entry(&mut *w, "system", b.shares_owner, b.no_asset, qty, "");
        add_entry(&mut *w, "system", b.collateral_owner, "SEDI", 0 - total, "");
        add_entry(&mut *w, ao.owner_kind, ao.account_id, "SEDI", yes_amount, "");
        add_entry(&mut *w, bo.owner_kind, bo.account_id, "SEDI", no_amount, "");
    }
    end_posting(&mut *w, posting);
    if w.error != "" { return; }
    if mode == "MINT" || mode == "MERGE" {
        let delta = qty; if mode == "MERGE" { delta = 0 - qty; }
        guard let cumulative = add_units(w.transition.supply_delta, delta) else { fail(&mut *w, "OVERFLOW"); return; }
        guard let pairs = add_units(b.pairs, cumulative) else { fail(&mut *w, "OVERFLOW"); return; }
        guard let collateral = mul_units(b.policy.V, pairs) else { fail(&mut *w, "INVALID_SUPPLY"); return; }
        w.transition.supply_delta = cumulative;
        w.transition.collateral_delta = collateral - b.collateral;
    }
    for step in 0..2 {
        let at = maker; if step == 1 { at = taker; }
        let u = w.updates[at]; u.order.remaining -= qty; u.order.filled += qty; w.updates[at] = u;
        charge_fee(at, &mut *w);
    }
    w.fills[w.transition.fill_count] = Fill { mode: mode, maker_order_id: w.updates[maker].order.id,
        taker_order_id: w.updates[taker].order.id, qty: qty, yes_price: price };
    w.transition.fill_count += 1; w.transition.last_price = price;
    let o = w.updates[maker].order;
    level_change(b, is_bid(o), price, 0 - qty, &mut *w);
}

fn fee_postings(w: &mut Workspace) {
    for i in 0..w.transition.update_count {
        let u = w.updates[i];
        if !u.fee_charged_now { continue; }
        let o = u.order;
        let posting = begin_posting(&mut *w, "FEE", "order", o.id);
        write_raw(&mut w.keys, "fee:"); write_raw(&mut w.keys, o.id);
        add_entry(&mut *w, o.owner_kind, o.account_id, "SEDI", -1, o.sedi_hold_id);
        add_hold(&mut *w, "consume", o, "SEDI", 1, o.sedi_hold_id);
        add_entry(&mut *w, "system", "system:fees", "SEDI", 1, "");
        end_posting(&mut *w, posting);
    }
}

fn release_hold(b: &Book, at: int, share: bool, target: int, w: &mut Workspace) {
    let u = w.updates[at]; let o = u.order;
    let available = o.sedi_original - o.sedi_consumed - o.sedi_released;
    let hold = o.sedi_hold_id; let asset = "SEDI";
    if share { available = o.shares_original - o.shares_consumed - o.shares_released; hold = o.share_hold_id; asset = order_asset(b, o); }
    if target < 0 || target > available { fail(&mut *w, "HOLD_EXCEEDED"); return; }
    let release = available - target;
    if release == 0 { return; }
    add_entry(&mut *w, o.owner_kind, o.account_id, asset, 0 - release, hold);
    add_entry(&mut *w, o.owner_kind, o.account_id, asset, release, "");
    add_hold(&mut *w, "release", o, asset, release, hold);
    if share { o.shares_released += release; } else { o.sedi_released += release; }
    u.order = o; w.updates[at] = u;
}

fn release_postings(b: &Book, w: &mut Workspace) {
    for i in 0..w.transition.update_count {
        let o = w.updates[i].order;
        let target = 0;
        if o.side == "BUY" {
            guard let amount = mul_units(o.remaining, o.limit) else { fail(&mut *w, "OVERFLOW"); return; }
            target = amount;
        }
        if o.remaining > 0 && !o.fee_paid { target += 1; }
        let posting = begin_posting(&mut *w, "ORDER_RELEASE", "order", o.id);
        write_raw(&mut w.keys, "release:"); write_raw(&mut w.keys, o.id); write_raw(&mut w.keys, ":"); write_decimal(&mut w.keys, w.transition.seq);
        release_hold(b, i, false, target, &mut *w);
        if o.side == "SELL" { release_hold(b, i, true, o.remaining, &mut *w); }
        if w.transition.entry_count > posting.entry_start { end_posting(&mut *w, posting); }
        else { w.keys.position = posting.key_start; }
        let u = w.updates[i];
        u.status = "OPEN";
        if o.remaining > 0 && o.filled > 0 { u.status = "PARTIAL"; }
        if o.remaining == 0 { u.status = "FILLED"; if o.cancelled > 0 { u.status = "CANCELLED"; } }
        w.updates[i] = u;
    }
}

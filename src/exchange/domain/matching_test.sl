import "encoding";
import "strings";

fn fixture_policy(v: int) -> Policy {
    return Policy { market_id: "00000000-0000-4000-a000-000000000900", season_id: "00000000-0000-4000-a000-000000000901",
        V: v, min_price: 1, max_price: v - 1, tick: 1, max_order_qty: 10000, min_order_notional: 2 };
}

fn fixture_id(n: int) -> str {
    let digits = to_str(n);
    return "00000000-0000-4000-a000-" + strings.repeat("0", 12 - len(digits)) + digits;
}

fn fixture_order(seq: int, number: int, account: int, outcome: str, side: str, price: int, qty: int) -> Order {
    let o = empty_order();
    o.id = fixture_id(number); o.account_id = fixture_id(account); o.owner_kind = "user";
    o.outcome = outcome; o.side = side; o.limit = price; o.qty = qty; o.remaining = qty; o.tif = "GTC";
    o.accepted_seq = seq; o.sedi_hold_id = fixture_id(100000 + number); o.sedi_original = 1;
    if side == "BUY" { o.sedi_original = price * qty + 1; }
    else { o.share_hold_id = fixture_id(200000 + number); o.shares_original = qty; }
    return o;
}

fn fixture_command(kind: str, seq: int) -> Command {
    return Command { kind: kind, seq: seq, ref: fixture_id(300000 + seq), order: empty_order(), order_id: "", account_id: "", system: false, reason: "USER_CANCEL" };
}

fn place_fixture(b: &mut Book, o: Order, w: &mut Workspace) {
    let cmd = fixture_command("Place", o.accepted_seq); cmd.ref = o.id; cmd.order = o;
    let before = physical_book(&*b);
    let error = plan(&*b, cmd, &mut *w); assert(error == "", error);
    assert(physical_book(&*b) == before, "planning changed the book");
    assert(full_hash(&*b, true, &mut *w) == "");
    let projected = hash_at(w.hashes.data, 64);
    let applied = apply(&mut *b, &mut *w); assert(applied == "", applied);
    let invariant = verify(&*b, &mut *w); assert(invariant == "", invariant);
    assert(full_hash(&*b, false, &mut *w) == "");
    assert(hash_at(w.hashes.data, 64) == projected);
}

fn physical_book(b: &Book) -> str {
    return inspect(b.policy) + b.mode + to_str(b.last_seq) + to_str(b.last_price) + to_str(b.pairs) + to_str(b.collateral) +
        to_str(b.reserved_yes) + to_str(b.reserved_no) + to_str(b.active_count) + to_str(b.best_bid) + to_str(b.best_ask) +
        inspect(b.bids) + inspect(b.asks) + inspect(b.slots) + inspect(b.index) + inspect(b.free_slots) + to_str(b.free_count) + encoding.hex_encode(to_bytes(b.digest.data));
}

fn test_transfer_releases_improvement_and_charges_fee_once() {
    let created = new_book(fixture_policy(100), 8, 1); guard let b = created else { panic("book"); }
    let w = new_workspace(&b, 8);
    place_fixture(&mut b, fixture_order(1, 1, 11, "YES", "SELL", 60, 1), &mut w);
    place_fixture(&mut b, fixture_order(2, 2, 12, "YES", "BUY", 75, 1), &mut w);
    assert(w.transition.fill_count == 1 && w.fills[0].mode == "TRANSFER_YES" && w.fills[0].yes_price == 60);
    assert(w.transition.posting_count == 4 && w.postings[3].kind == "ORDER_RELEASE");
    assert(w.holds[w.postings[3].hold_start].amount == 15 && b.pairs == 1 && b.active_count == 0);
}

fn test_mint_then_merge_at_maker_price_and_variable_payout() {
    for v in [100, 200] {
        let created = new_book(fixture_policy(v), 8, 0); guard let b = created else { panic("book"); }
        let w = new_workspace(&b, 8);
        place_fixture(&mut b, fixture_order(1, 1, 11, "NO", "BUY", v - 55, 1), &mut w);
        place_fixture(&mut b, fixture_order(2, 2, 12, "YES", "BUY", 70, 1), &mut w);
        assert(w.fills[0].mode == "MINT" && b.collateral == v && b.pairs == 1);
        place_fixture(&mut b, fixture_order(3, 3, 11, "NO", "SELL", v - 60, 1), &mut w);
        place_fixture(&mut b, fixture_order(4, 4, 12, "YES", "SELL", 50, 1), &mut w);
        assert(w.fills[0].mode == "MERGE" && w.fills[0].yes_price == 60 && b.collateral == 0 && b.pairs == 0);
    }
}

fn test_fifo_mixes_modes_partial_fee_and_ioc() {
    let created = new_book(fixture_policy(100), 8, 3); guard let b = created else { panic("book"); }
    let w = new_workspace(&b, 8);
    place_fixture(&mut b, fixture_order(1, 1, 11, "YES", "SELL", 58, 3), &mut w);
    place_fixture(&mut b, fixture_order(2, 2, 12, "NO", "BUY", 42, 5), &mut w);
    place_fixture(&mut b, fixture_order(3, 3, 13, "YES", "BUY", 60, 6), &mut w);
    assert(w.transition.fill_count == 2 && w.fills[0].mode == "TRANSFER_YES" && w.fills[1].mode == "MINT");
    let o = fixture_order(4, 4, 14, "YES", "BUY", 58, 10); o.tif = "IOC";
    place_fixture(&mut b, o, &mut w);
    assert(w.updates[0].order.id == fixture_id(2) && !w.updates[0].fee_charged_now);
    assert(w.updates[1].order.cancelled == 8 && w.updates[1].fee_charged_now && b.active_count == 0);
}

fn test_self_prevention_preserves_maker_and_allows_earlier_fills() {
    let created = new_book(fixture_policy(100), 8, 3); guard let b = created else { panic("book"); }
    let w = new_workspace(&b, 8);
    place_fixture(&mut b, fixture_order(1, 1, 11, "YES", "SELL", 55, 1), &mut w);
    let maker = fixture_order(2, 2, 12, "YES", "SELL", 58, 2); maker.owner_group = fixture_id(777);
    place_fixture(&mut b, maker, &mut w);
    let incoming = fixture_order(3, 3, 13, "YES", "BUY", 60, 4); incoming.owner_group = maker.owner_group;
    place_fixture(&mut b, incoming, &mut w);
    assert(w.transition.fill_count == 1 && w.updates[1].order.cancelled == 3 && w.updates[1].cancel_reason == "SELF_TRADE_PREVENTED");
    assert(b.active_count == 1 && b.slots[find_order(&b, maker.id, w.scratch.data)].order.remaining == 2);
}

fn test_full_slot_pool_reuses_terminal_slot_and_rejects_stale_apply() {
    let created = new_book(fixture_policy(100), 1, 1); guard let b = created else { panic("book"); }
    let w = new_workspace(&b, 2);
    place_fixture(&mut b, fixture_order(1, 1, 11, "YES", "SELL", 58, 1), &mut w);
    place_fixture(&mut b, fixture_order(2, 2, 12, "YES", "BUY", 60, 2), &mut w);
    assert(b.active_count == 1 && b.free_count == 0 && b.slots[0].order.id == fixture_id(2) && b.slots[0].generation == 2);
    assert(apply(&mut b, &mut w) == "NO_PLAN");
    let cmd = fixture_command("Close", 3);
    assert(plan(&b, cmd, &mut w) == "");
    let before = physical_book(&b);
    w.hashes.data[32] = w.hashes.data[32] ^ 1;
    assert(apply(&mut b, &mut w) == "TRANSITION_HASH_MISMATCH");
    assert(physical_book(&b) == before);
    assert(plan(&b, cmd, &mut w) == "");
    assert(apply(&mut b, &mut w) == "");
    assert(b.mode == "CLOSED" && b.active_count == 0 && verify(&b, &mut w) == "");
}

fn hash_at(data: wire, at: int) -> str {
    let text = byte_writer(64); write_hex(&mut text, data, at, 32); return to_str(to_bytes(text.data));
}

fn test_restore_rebuilds_priority_and_depth_independently_of_slots() {
    let created = new_book(fixture_policy(100), 4, 3); guard let b = created else { panic("book"); }
    let w = new_workspace(&b, 4);
    place_fixture(&mut b, fixture_order(1, 1, 11, "YES", "SELL", 60, 2), &mut w);
    place_fixture(&mut b, fixture_order(2, 2, 12, "NO", "BUY", 40, 3), &mut w);
    place_fixture(&mut b, fixture_order(3, 3, 13, "YES", "BUY", 50, 2), &mut w);
    let saved = snapshot(&b); let first = saved.orders[0]; saved.orders[0] = saved.orders[2]; saved.orders[2] = first;
    let rebuilt = restore(saved, 8); guard let copy = rebuilt else let e = err_of(rebuilt) { panic(e); }
    let scratch = new_workspace(&copy, 8);
    assert(full_hash(&b, false, &mut w) == "");
    assert(full_hash(&copy, false, &mut scratch) == "");
    assert(hash_at(w.hashes.data, 64) == hash_at(scratch.hashes.data, 64));
    let depth = depth_buffer(2);
    assert(top_levels(&copy, 2, &mut depth) == "");
    assert(depth.bid_count == 1 && depth.bids[0].yes_price == 50 && depth.ask_count == 1 && depth.asks[0].new_level_qty == 5);
    assert(depth_at(&copy, 60).ask_qty == 5);
    place_fixture(&mut copy, fixture_order(4, 4, 14, "YES", "BUY", 60, 3), &mut scratch);
    assert(scratch.transition.fill_count == 2 && scratch.fills[0].maker_order_id == fixture_id(1) && scratch.fills[1].maker_order_id == fixture_id(2));
}

fn test_failed_plan_clears_partial_effects_and_preserves_physical_state() {
    let created = new_book(fixture_policy(100), 4, 2); guard let b = created else { panic("book"); }
    let w = new_workspace(&b, 4);
    place_fixture(&mut b, fixture_order(1, 1, 11, "YES", "SELL", 58, 1), &mut w);
    place_fixture(&mut b, fixture_order(2, 2, 12, "YES", "SELL", 60, 1), &mut w);
    let at = find_order(&b, fixture_id(2), w.scratch.data); let corrupt = b.slots[at]; corrupt.order.limit = 101; b.slots[at] = corrupt;
    let before = physical_book(&b);
    let cmd = fixture_command("Place", 3); cmd.order = fixture_order(3, 3, 13, "YES", "BUY", 70, 2);
    assert(plan(&b, cmd, &mut w) == "INTERNAL_PRICE_OUT_OF_BAND");
    assert(!w.ready && w.transition.fill_count == 0 && w.transition.posting_count == 0 && physical_book(&b) == before);
    let invalid = fixture_command("Place", 3); invalid.order = fixture_order(3, 4, 14, "YES", "BUY", 70, 2);
    invalid.order.sedi_original = max_units();
    assert(plan(&b, invalid, &mut w) == "INVALID_HOLD_FACTS");
    assert(physical_book(&b) == before);
    if let _bad = mul_units(max_units(), 2) { panic("multiplication overflow accepted"); }
    if let _bad = add_units(max_units(), 1) { panic("addition overflow accepted"); }
}

fn test_capacity_failures_and_foreign_workspace_leave_book_unchanged() {
    let created = new_book(fixture_policy(100), 4, 3); guard let b = created else { panic("book"); }
    let small = new_workspace(&b, 1); let w = new_workspace(&b, 4);
    place_fixture(&mut b, fixture_order(1, 1, 11, "YES", "SELL", 55, 1), &mut w);
    place_fixture(&mut b, fixture_order(2, 2, 12, "YES", "SELL", 56, 1), &mut w);
    let before = physical_book(&b);
    let cmd = fixture_command("Place", 3); cmd.order = fixture_order(3, 3, 13, "YES", "BUY", 60, 2);
    assert(plan(&b, cmd, &mut small) == "NEED_CAPACITY");
    assert(!small.ready && physical_book(&b) == before);
    let other = new_book(fixture_policy(10), 4, 0); guard let foreign = other else { panic("book"); }
    let scratch = new_workspace(&foreign, 4);
    assert(plan(&b, cmd, &mut scratch) == "WORKSPACE_MISMATCH");
    assert(physical_book(&b) == before);
    assert(plan(&b, cmd, &mut w) == "");
    assert(apply(&mut b, &mut w) == "");
    assert(verify(&b, &mut w) == "");
}

fn test_authoritative_rejection_releases_verified_holds_without_changing_mode_or_makers() {
    let created = new_book(fixture_policy(100), 4, 0); guard let b = created else { panic("book"); }
    let w = new_workspace(&b, 4);
    place_fixture(&mut b, fixture_order(1, 1, 11, "NO", "BUY", 40, 2), &mut w);
    let maker = b.slots[0].order;
    let cmd = fixture_command("RejectPlace", 2); cmd.order = fixture_order(2, 2, 12, "YES", "BUY", 70, 2); cmd.reason = "TRADING_HALTED";
    assert(plan(&b, cmd, &mut w) == "");
    assert(w.transition.decision == "TRADING_HALTED" && w.transition.fill_count == 0 && w.transition.posting_count == 1);
    assert(w.holds[0].op == "release" && w.holds[0].amount == 141 && !w.updates[0].fee_charged_now);
    assert(apply(&mut b, &mut w) == "");
    assert(b.mode == "OPEN" && b.pairs == 0 && b.active_count == 1 && inspect(b.slots[0].order) == inspect(maker));
    assert(verify(&b, &mut w) == "");
    cmd.seq = 3; cmd.order = fixture_order(3, 3, 12, "YES", "BUY", 70, 2); cmd.reason = "user chosen reason";
    let before = physical_book(&b);
    assert(plan(&b, cmd, &mut w) == "INVALID_REJECTION_REASON");
    assert(!w.ready && physical_book(&b) == before);
}

fn test_cancel_all_cancels_all_resting_orders_for_account_in_one_transition() {
    let created = new_book(fixture_policy(100), 8, 10); guard let b = created else { panic("book"); }
    let w = new_workspace(&b, 8);
    // Account 11 places two resting orders on different levels/sides
    place_fixture(&mut b, fixture_order(1, 1, 11, "YES", "SELL", 60, 2), &mut w);
    place_fixture(&mut b, fixture_order(2, 2, 11, "NO", "BUY", 35, 3), &mut w);
    // Account 12 places one resting order
    place_fixture(&mut b, fixture_order(3, 3, 12, "YES", "SELL", 65, 4), &mut w);
    assert(b.active_count == 3);

    // CancelAll for Account 11
    let cmd = fixture_command("CancelAll", 4);
    cmd.account_id = fixture_id(11);
    cmd.reason = "USER_CANCEL";
    assert(plan(&b, cmd, &mut w) == "");
    assert(w.transition.update_count == 2);
    assert(w.updates[0].order.account_id == fixture_id(11) && w.updates[0].order.cancelled > 0);
    assert(w.updates[1].order.account_id == fixture_id(11) && w.updates[1].order.cancelled > 0);
    assert(apply(&mut b, &mut w) == "");
    assert(verify(&b, &mut w) == "");

    // Account 11 orders are gone, Account 12 order remains intact
    assert(b.active_count == 1);
    let rem_slot = find_order(&b, fixture_id(3), w.scratch.data);
    assert(rem_slot >= 0);
    assert(b.slots[rem_slot].order.account_id == fixture_id(12));
}


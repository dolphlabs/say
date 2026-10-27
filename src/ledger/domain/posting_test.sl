import "encoding";

fn sid() -> str { return "11111111-1111-4111-8111-111111111111"; }
fn alice() -> str { return "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"; }
fn bob() -> str { return "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"; }
fn mkt() -> str { return "cccccccc-cccc-4ccc-8ccc-cccccccccccc"; }

fn transfer(amount: int) -> LedgerTx {
    let none_holds: [HoldOp] = [];
    return LedgerTx { business_key: "t:1", kind: "ADJUSTMENT", season_id: sid(), market_id: "", ref_type: "",
                      ref_id: "", metadata: "{}", entries: [free(user(alice()), sedi(), 0 - amount),
                      free(user(bob()), sedi(), amount)], holds: none_holds };
}

fn fault_of(tx: LedgerTx) -> str {
    guard let e = validate(tx) else {
        return "ok";
    }
    return fault_name(e.fault);
}

fn test_should_accept_a_balanced_transfer() {
    assert(fault_of(transfer(5)) == "ok");
}

fn test_should_refuse_fewer_than_two_entries_and_zero_deltas() {
    let tx = transfer(5);
    tx.entries = [free(user(alice()), sedi(), 5)];
    assert(fault_of(tx) == "Malformed");
    let z = transfer(5);
    z.entries = [free(user(alice()), sedi(), 0), free(user(bob()), sedi(), 0)];
    assert(fault_of(z) == "Malformed");
}

fn test_should_refuse_a_posting_that_does_not_sum_to_zero_per_asset() {
    let tx = transfer(5);
    tx.entries = [free(user(alice()), sedi(), -5), free(user(bob()), yes_asset(mkt()), 5)];
    guard let e = validate(tx) else { panic("accepted"); }
    assert(e.fault == Fault.Unbalanced);
}

fn test_should_count_a_move_between_buckets_as_balanced() {
    let tx = hold_tx(user(alice()), sid(), sedi(), 50, "order", "o1", "hold:o1", "{}");
    assert(fault_of(tx) == "ok");
}

fn test_should_refuse_sums_that_overflow() {
    let tx = transfer(5);
    tx.entries = [free(user(alice()), sedi(), max_units()), free(user(bob()), sedi(), max_units()),
                  free(issuance(), sedi(), -2)];
    assert(fault_of(tx) == "Overflow");
}

fn test_should_refuse_held_entries_without_a_hold() {
    let tx = transfer(5);
    tx.entries = [free(user(alice()), sedi(), -5), held(user(alice()), sedi(), 5, "")];
    assert(fault_of(tx) == "Malformed");
}

fn test_should_refuse_a_held_bucket_on_system_wallets() {
    let tx = transfer(5);
    tx.entries = [free(user(alice()), sedi(), -5), held(fees(), sedi(), 5, new_hold())];
    assert(fault_of(tx) == "Malformed");
}

fn test_should_refuse_bad_assets_and_owners() {
    let tx = transfer(5);
    tx.entries = [free(user(alice()), "YES:nope", -5), free(user(bob()), "YES:nope", 5)];
    assert(fault_of(tx) == "Malformed");
    let o = transfer(5);
    o.entries = [free(user("not-a-uuid"), sedi(), -5), free(user(bob()), sedi(), 5)];
    assert(fault_of(o) == "Malformed");
}

fn test_should_check_asset_keys() {
    assert(valid_asset("SEDI"));
    assert(valid_asset(yes_asset(mkt())));
    assert(valid_asset(no_asset(mkt())));
    assert(!valid_asset("YES:" + "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC"));
    assert(!valid_asset("MAYBE:" + mkt()));
}

fn test_should_hash_the_same_movement_the_same_whatever_the_order_or_metadata() {
    let a = transfer(5);
    let b = transfer(5);
    b.entries = [b.entries[1], b.entries[0]];
    b.metadata = "{\"note\":\"retry\"}";
    assert(encoding.hex_encode(payload_hash(a)) == encoding.hex_encode(payload_hash(b)));
    let c = transfer(6);
    assert(encoding.hex_encode(payload_hash(a)) != encoding.hex_encode(payload_hash(c)));
    let d = transfer(5);
    d.ref_id = "x";
    assert(encoding.hex_encode(payload_hash(a)) != encoding.hex_encode(payload_hash(d)));
}

fn test_should_not_let_fields_bleed_into_each_other_in_the_hash() {
    let a = transfer(5);
    a.ref_type = "ab";
    a.ref_id = "c";
    let b = transfer(5);
    b.ref_type = "a";
    b.ref_id = "bc";
    assert(encoding.hex_encode(payload_hash(a)) != encoding.hex_encode(payload_hash(b)));
}

fn state(owner: str, free_units: int, held_units: int) -> WalletState {
    return WalletState { wallet_id: "w-" + owner, owner_id: owner, asset_key: sedi(), free: free_units,
                         held: held_units, free_before: free_units, held_before: held_units };
}

fn test_should_report_insufficient_funds_against_the_balance_before() {
    let states = [state(alice(), 3, 0), state(bob(), 0, 0)];
    guard let e = apply(states, transfer(5).entries) else { panic("allowed overdraft"); }
    assert(e.fault == Fault.InsufficientFunds);
    assert(e.wallet == alice() && e.needed == 5 && e.available == 3, inspect(e));
}

fn test_should_apply_balances_when_funded() {
    let states = [state(alice(), 10, 0), state(bob(), 1, 0)];
    if let e = apply(states, transfer(5).entries) {
        panic(inspect(e));
    }
    assert(states[0].free == 5 && states[1].free == 6);
}

fn test_should_round_trip_errors_through_text() {
    let e = insufficient(alice(), sedi(), 7, 6);
    e.detail = "a|b";
    let back = decode(encode(e));
    assert(back.fault == Fault.InsufficientFunds);
    assert(back.wallet == alice() && back.needed == 7 && back.available == 6 && back.detail == "a|b");
    assert(decode("connection reset").fault == Fault.Store);
}

fn test_should_check_arithmetic() {
    assert((checked_add(max_units(), 1) ?? -1) == -1);
    assert((checked_add(0 - max_units() - 1, -1) ?? 1) == 1);
    assert((checked_add(2, 3) ?? 0) == 5);
    assert((checked_mul(max_units(), 2) ?? -1) == -1);
    assert((checked_mul(-4, 5) ?? 0) == -20);
}

fn test_should_split_the_cap_into_whole_grants_across_shards() {
    let total = 0;
    for i in 0..budget_shards() {
        let b = shard_budget(10000007, 1000, i);
        assert(b % 1000 == 0);
        total = total + b;
    }
    assert(total == 10000000, to_str(total));
    assert(shard_budget(2000, 1000, 0) == 1000 && shard_budget(2000, 1000, 1) == 1000 && shard_budget(2000, 1000, 2) == 0);
    assert(shard_of(alice()) >= 0 && shard_of(alice()) < 16);
    assert(shard_of(alice()) == shard_of(alice()));
}

fn test_should_build_a_balanced_grant_keyed_by_season_and_account() {
    let g = grant_tx(alice(), sid(), 1000);
    assert(fault_of(g) == "ok");
    assert(g.business_key == "grant:" + sid() + ":" + alice());
}

fn test_should_build_release_and_consume_that_match_their_hold() {
    let h = HoldInfo { id: "dddddddd-dddd-4ddd-8ddd-dddddddddddd", owner: user(alice()), asset_key: sedi(),
                       season_id: sid(), ref_type: "order", ref_id: "o1", status: "open", remaining: 50 };
    assert(fault_of(release_tx(h, 20, "release:o1", "{}")) == "ok");
    assert(fault_of(consume_tx(h, 30, "FILL", [free(user(bob()), sedi(), 29), free(fees(), sedi(), 1)],
                               "fill:o1", "{}")) == "ok");
    let bad = consume_tx(h, 30, "FILL", [free(user(bob()), sedi(), 30)], "fill:o1", "{}");
    bad.holds[0].amount = 31;
    assert(fault_of(bad) == "Malformed");
}

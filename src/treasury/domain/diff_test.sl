pub fn test_order_diff_20_percent_tolerance() {
    let desired = [
        DesiredOrder { outcome: "YES", side: "BUY", price: 53, qty: 10 },
        DesiredOrder { outcome: "YES", side: "SELL", price: 57, qty: 10 }
    ];

    let live = [
        LiveOrder { id: "o1", outcome: "YES", side: "BUY", price: 53, qty: 9 },
        LiveOrder { id: "o2", outcome: "YES", side: "SELL", price: 57, qty: 7 },
        LiveOrder { id: "o3", outcome: "YES", side: "BUY", price: 50, qty: 5 }
    ];

    let diff = compute_order_diff(live, desired);

    // o1 should be kept
    assert(len(diff.to_keep) == 1, "to_keep should have 1 order");
    assert(diff.to_keep[0].id == "o1", "o1 kept");

    // o2 and o3 should be cancelled
    assert(len(diff.to_cancel) == 2, "to_cancel should have 2 orders");

    // Desired sell @ 57 should be placed as replacement
    assert(len(diff.to_place) == 1, "to_place should have 1 order");
    assert(diff.to_place[0].side == "SELL" && diff.to_place[0].price == 57, "replace sell order");
}

pub fn test_idempotency_key_deterministic() {
    let k1 = make_idempotency_key("bot1", "mkt1", 0, 53, 10);
    let k2 = make_idempotency_key("bot1", "mkt1", 0, 53, 10);
    let k3 = make_idempotency_key("bot1", "mkt1", 1, 52, 6);
    assert(k1 == k2, "keys for same params should match");
    assert(k1 != k3, "keys for different levels/prices should differ");
}

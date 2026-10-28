pub fn test_golden_worked_example_quoting() {
    let inputs = QuoteInputs {
        V: 100,
        min_price: 1,
        max_price: 99,
        tick: 1,
        ref_price: 57,
        ref_age_ms: 1200,
        book_top: BookTop { yes_bid: none, yes_ask: none },
        inventory: Inventory {
            yes_qty: 140,
            no_qty: 0,
            cost_yes: 7700,
            cost_no: 0
        },
        cash_free: 42300,
        allocation: 50000,
        budget_used: 7700,
        params: BotParams {
            base_spread_ticks: 2,
            vol_ticks: 0,
            skew_ticks: 4,
            levels: 3,
            base_size: 10,
            max_net_shares: 400,
            max_loss: 15000,
            season_max_drawdown: 100000,
            min_requote_ms: 250,
            max_ops_per_sec: 10,
            max_open_orders: 20
        },
        recent_fills: [],
        market_status: "OPEN",
        trading_halted: false,
        global_pause: false,
        manual_pause: false,
        season_drawdown: 0,
        now_ms: 100000
    };

    let res = quote(inputs);

    assert(res.status == "QUOTING", "status should be QUOTING");
    assert(res.status_label == "Quoting", "status_label should be Quoting");
    assert(res.r_prime == 55, "r_prime should be 55");
    assert(res.spread_ticks == 3, "spread_ticks should be 3");
    assert(res.util == 3500, "util should be 3500");
    assert(res.worst_case_loss == 7700, "worst_case_loss should be 7700");
    assert(len(res.orders) == 6, "orders count should be 6");

    // Bids
    assert(res.orders[0].outcome == "YES", "orders[0].outcome");
    assert(res.orders[0].side == "BUY", "orders[0].side");
    assert(res.orders[0].price == 53, "orders[0].price");
    assert(res.orders[0].qty == 10, "orders[0].qty");

    assert(res.orders[1].outcome == "YES", "orders[1].outcome");
    assert(res.orders[1].side == "BUY", "orders[1].side");
    assert(res.orders[1].price == 52, "orders[1].price");
    assert(res.orders[1].qty == 6, "orders[1].qty");

    assert(res.orders[2].outcome == "YES", "orders[2].outcome");
    assert(res.orders[2].side == "BUY");
    assert(res.orders[2].price == 51);
    assert(res.orders[2].qty == 3);

    // Asks
    assert(res.orders[3].outcome == "YES", "orders[3].outcome");
    assert(res.orders[3].side == "SELL", "orders[3].side");
    assert(res.orders[3].price == 57, "orders[3].price");
    assert(res.orders[3].qty == 10, "orders[3].qty");

    assert(res.orders[4].outcome == "YES", "orders[4].outcome");
    assert(res.orders[4].side == "SELL", "orders[4].side");
    assert(res.orders[4].price == 58, "orders[4].price");
    assert(res.orders[4].qty == 6, "orders[4].qty");

    assert(res.orders[5].outcome == "YES", "orders[5].outcome");
    assert(res.orders[5].side == "SELL", "orders[5].side");
    assert(res.orders[5].price == 59, "orders[5].price");
    assert(res.orders[5].qty == 3, "orders[5].qty");
}

pub fn test_hard_stops() {
    let base = QuoteInputs {
        V: 100,
        min_price: 1,
        max_price: 99,
        tick: 1,
        ref_price: 50,
        ref_age_ms: 1000,
        book_top: BookTop { yes_bid: none, yes_ask: none },
        inventory: Inventory { yes_qty: 0, no_qty: 0, cost_yes: 0, cost_no: 0 },
        cash_free: 50000,
        allocation: 50000,
        budget_used: 0,
        params: default_params(),
        recent_fills: [],
        market_status: "OPEN",
        trading_halted: false,
        global_pause: false,
        manual_pause: false,
        season_drawdown: 0,
        now_ms: 100000
    };

    // 1. Global pause
    let q1 = base;
    q1.global_pause = true;
    let r1 = quote(q1);
    assert(r1.status == "PAUSED_ALL", "status PAUSED_ALL");
    assert(r1.status_label == "Paused · all bots", "status_label Paused · all bots");
    assert(len(r1.orders) == 0, "orders empty");

    // 2. Manual pause
    let q2 = base;
    q2.manual_pause = true;
    let r2 = quote(q2);
    assert(r2.status == "PAUSED_MANUAL", "status PAUSED_MANUAL");
    assert(r2.status_label == "Paused by you", "status_label Paused by you");
    assert(len(r2.orders) == 0, "orders empty");

    // 3. Market not open
    let q3 = base;
    q3.market_status = "CLOSED";
    let r3 = quote(q3);
    assert(r3.status == "PULLED_MARKET", "status PULLED_MARKET");
    assert(r3.status_label == "Pulled · market halted", "status_label Pulled · market halted");
    assert(len(r3.orders) == 0, "orders empty");

    // 4. Stale data
    let q4 = base;
    q4.ref_age_ms = 35000;
    let r4 = quote(q4);
    assert(r4.status == "PULLED_STALE", "status PULLED_STALE");
    assert(r4.status_label == "Pulled · old data", "status_label Pulled · old data");
    assert(len(r4.orders) == 0, "orders empty");

    // 5. Drawdown exceeded
    let q5 = base;
    q5.season_drawdown = 120000;
    let r5 = quote(q5);
    assert(r5.status == "PULLED_DRAWDOWN", "status PULLED_DRAWDOWN");
    assert(r5.status_label == "Pulled · drawdown", "status_label Pulled · drawdown");
    assert(len(r5.orders) == 0, "orders empty");
}

pub fn test_native_share_reuse_holding_no() {
    let inputs = QuoteInputs {
        V: 100,
        min_price: 1,
        max_price: 99,
        tick: 1,
        ref_price: 50,
        ref_age_ms: 500,
        book_top: BookTop { yes_bid: none, yes_ask: none },
        inventory: Inventory {
            yes_qty: 0,
            no_qty: 50,
            cost_yes: 0,
            cost_no: 2500
        },
        cash_free: 5000,
        allocation: 50000,
        budget_used: 2500,
        params: default_params(),
        recent_fills: [],
        market_status: "OPEN",
        trading_halted: false,
        global_pause: false,
        manual_pause: false,
        season_drawdown: 0,
        now_ms: 100000
    };

    let res = quote(inputs);
    assert(res.status == "QUOTING", "status QUOTING");
    // Since bot holds 50 NO shares, for bids on YES it sells NO
    assert(res.orders[0].outcome == "NO", "orders[0].outcome NO");
    assert(res.orders[0].side == "SELL", "orders[0].side SELL");
}

pub fn test_worst_case_loss_pulled_cap() {
    let inputs = QuoteInputs {
        V: 100,
        min_price: 1,
        max_price: 99,
        tick: 1,
        ref_price: 50,
        ref_age_ms: 500,
        book_top: BookTop { yes_bid: none, yes_ask: none },
        inventory: Inventory {
            yes_qty: 600,
            no_qty: 0,
            cost_yes: 35000,
            cost_no: 0
        },
        cash_free: 10000,
        allocation: 50000,
        budget_used: 35000,
        params: BotParams {
            base_spread_ticks: 2,
            vol_ticks: 0,
            skew_ticks: 4,
            levels: 3,
            base_size: 10,
            max_net_shares: 400,
            max_loss: 20000, // lower than loss_if_no = 35000
            season_max_drawdown: 100000,
            min_requote_ms: 250,
            max_ops_per_sec: 10,
            max_open_orders: 20
        },
        recent_fills: [],
        market_status: "OPEN",
        trading_halted: false,
        global_pause: false,
        manual_pause: false,
        season_drawdown: 0,
        now_ms: 100000
    };

    let res = quote(inputs);
    assert(res.status == "PULLED_CAP", "status should be PULLED_CAP");
    assert(res.status_label == "Pulled · holding cap", "label should be Pulled · holding cap");
    assert(res.worst_case_loss == 35000, "worst-case loss should be 35000");
    // Only risk-reducing asks (selling YES) are emitted, no bids
    for o in res.orders {
        assert(o.side == "SELL" && o.outcome == "YES", "only sell YES allowed to de-risk");
    }
}

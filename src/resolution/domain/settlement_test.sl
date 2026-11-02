fn test_yes_wins_settlement() {
    let positions: [AccountPositionSnapshot] = [
        AccountPositionSnapshot {
            account_id: "acct_remo",
            outcome: "YES",
            qty: 10,
            cost_basis: 400,
            fees_paid: 1,
            realized_pnl: 0
        },
        AccountPositionSnapshot {
            account_id: "acct_sporting",
            outcome: "NO",
            qty: 10,
            cost_basis: 600,
            fees_paid: 1,
            realized_pnl: 0
        }
    ];

    let results = calculate_yes_no_results("YES", 100, positions);
    assert(len(results) == 2);

    // Remo: 10 Yes @ 40 -> paid_out 1000, pnl +599, WON
    let remo = results[0];
    assert(remo.account_id == "acct_remo");
    assert(remo.paid_out == 1000);
    assert(remo.pnl == 599);
    assert(remo.result_outcome == result_won());

    // Sporting: 10 No @ 60 -> paid_out 0, pnl -601, LOST
    let sporting = results[1];
    assert(sporting.account_id == "acct_sporting");
    assert(sporting.paid_out == 0);
    assert(sporting.pnl == -601);
    assert(sporting.result_outcome == result_lost());
}

fn test_no_wins_v200_settlement() {
    let positions: [AccountPositionSnapshot] = [
        AccountPositionSnapshot {
            account_id: "acct_yes",
            outcome: "YES",
            qty: 3,
            cost_basis: 360,
            fees_paid: 1,
            realized_pnl: 0
        },
        AccountPositionSnapshot {
            account_id: "acct_no",
            outcome: "NO",
            qty: 3,
            cost_basis: 240,
            fees_paid: 1,
            realized_pnl: 0
        }
    ];

    let results = calculate_yes_no_results("NO", 200, positions);
    assert(len(results) == 2);

    let no_holder = results[1];
    assert(no_holder.paid_out == 600);
    assert(no_holder.pnl == 359);
    assert(no_holder.result_outcome == result_won());

    let yes_holder = results[0];
    assert(yes_holder.paid_out == 0);
    assert(yes_holder.pnl == -361);
    assert(yes_holder.result_outcome == result_lost());
}

fn test_golden_void_worked_example_3_4() {
    // A: sold out before void (qty 0, basis 0, fees_paid 2, realized_pnl +50)
    // B: holds 1 No (basis 60, fees_paid 1, realized_pnl 0)
    // C: holds 1 Yes (basis 90, fees_paid 1, realized_pnl 0)
    let positions: [AccountPositionSnapshot] = [
        AccountPositionSnapshot {
            account_id: "A",
            outcome: "YES",
            qty: 0,
            cost_basis: 0,
            fees_paid: 2,
            realized_pnl: 50
        },
        AccountPositionSnapshot {
            account_id: "B",
            outcome: "NO",
            qty: 1,
            cost_basis: 60,
            fees_paid: 1,
            realized_pnl: 0
        },
        AccountPositionSnapshot {
            account_id: "C",
            outcome: "YES",
            qty: 1,
            cost_basis: 90,
            fees_paid: 1,
            realized_pnl: 0
        }
    ];

    let fee_orders: [OrderFeeRefundItem] = [
        OrderFeeRefundItem { order_id: "ord_a1", account_id: "A", fee_amount: 1 },
        OrderFeeRefundItem { order_id: "ord_a2", account_id: "A", fee_amount: 1 },
        OrderFeeRefundItem { order_id: "ord_b1", account_id: "B", fee_amount: 1 },
        OrderFeeRefundItem { order_id: "ord_c1", account_id: "C", fee_amount: 1 }
    ];

    let results = calculate_void_results(positions, fee_orders);
    assert(len(results) == 3);

    // A: keeps +50 realized sale, -2 fees + 2 fee refunds = +50 PnL
    let a_res = results[0];
    assert(a_res.account_id == "A");
    assert(a_res.paid_out == 0);
    assert(a_res.fees_refunded == 2);
    assert(a_res.pnl == 50);
    assert(a_res.result_outcome == result_voided());

    // B: basis 60 refunded, -1 fee + 1 fee refund = 0 PnL
    let b_res = results[1];
    assert(b_res.account_id == "B");
    assert(b_res.paid_out == 60);
    assert(b_res.fees_refunded == 1);
    assert(b_res.pnl == 0);
    assert(b_res.result_outcome == result_voided());

    // C: basis 90 refunded, -1 fee + 1 fee refund = 0 PnL
    let c_res = results[2];
    assert(c_res.account_id == "C");
    assert(c_res.paid_out == 90);
    assert(c_res.fees_refunded == 1);
    assert(c_res.pnl == 0);
    assert(c_res.result_outcome == result_voided());

    // Settlement preview
    let preview = build_settlement_preview(outcome_void(), 100, 100, positions, fee_orders, default_void_shortfall_threshold());
    assert(preview.collateral_released == 100);
    assert(preview.refunds_total == 150);
    assert(preview.fee_refunds_total == 4);
    assert(preview.treasury_delta == -50);
    assert(preview.shortfall == 50);
    assert(!preview.needs_second_approval);
}

fn test_void_large_shortfall_safeguard() {
    let positions: [AccountPositionSnapshot] = [
        AccountPositionSnapshot {
            account_id: "whale",
            outcome: "YES",
            qty: 1000,
            cost_basis: 60000,
            fees_paid: 1,
            realized_pnl: 0
        }
    ];
    let fee_orders: [OrderFeeRefundItem] = [];
    // Collateral is only 5,000, refunds are 60,000 -> shortfall is 55,000 (> 50,000 threshold)
    let preview = build_settlement_preview(outcome_void(), 100, 5000, positions, fee_orders, default_void_shortfall_threshold());
    assert(preview.shortfall == 55000);
    assert(preview.needs_second_approval);
}

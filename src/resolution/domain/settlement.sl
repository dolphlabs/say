// Pure settlement calculations for Yes/No wins and Void refunds

pub fn calculate_yes_no_results(
    winning_outcome: str,
    redemption_v: int,
    positions: [AccountPositionSnapshot]
) -> [CalculatedResultItem] {
    let items: [CalculatedResultItem] = [];
    for p in positions {
        let is_winner = p.outcome == winning_outcome;
        let payout = 0;
        let res_kind = result_lost();
        if is_winner {
            payout = p.qty * redemption_v;
            res_kind = result_won();
        }
        // pnl = paid_out + realized_pnl_from_sells - cost_basis - fees
        let pnl = payout + p.realized_pnl - p.cost_basis - p.fees_paid;
        push(items, CalculatedResultItem {
            account_id: p.account_id,
            outcome: p.outcome,
            qty: p.qty,
            cost_basis: p.cost_basis,
            fees: p.fees_paid,
            fees_refunded: 0,
            paid_out: payout,
            pnl: pnl,
            result_outcome: res_kind
        });
    }
    return items;
}

pub fn calculate_void_results(
    positions: [AccountPositionSnapshot],
    fee_orders: [OrderFeeRefundItem]
) -> [CalculatedResultItem] {
    let items: [CalculatedResultItem] = [];
    for p in positions {
        // Account fee refund sum
        let acct_fee_refund = 0;
        for fo in fee_orders {
            if fo.account_id == p.account_id {
                acct_fee_refund = acct_fee_refund + fo.fee_amount;
            }
        }

        // Void refund: cost_basis returned
        let refund = p.cost_basis;
        // pnl = realized_pnl_from_sells + fees_refunded - fees
        let pnl = p.realized_pnl + acct_fee_refund - p.fees_paid;

        push(items, CalculatedResultItem {
            account_id: p.account_id,
            outcome: p.outcome,
            qty: p.qty,
            cost_basis: p.cost_basis,
            fees: p.fees_paid,
            fees_refunded: acct_fee_refund,
            paid_out: refund,
            pnl: pnl,
            result_outcome: result_voided()
        });
    }
    return items;
}

pub fn build_settlement_preview(
    outcome: str,
    redemption_v: int,
    initial_collateral: int,
    positions: [AccountPositionSnapshot],
    fee_orders: [OrderFeeRefundItem],
    shortfall_threshold: int
) -> SettlementPreview {
    let burned_yes = 0;
    let burned_no = 0;
    let winners = 0;
    let payout_total = 0;
    let refunds_total = 0;

    for p in positions {
        if p.outcome == outcome_yes() {
            burned_yes = burned_yes + p.qty;
        } else if p.outcome == outcome_no() {
            burned_no = burned_no + p.qty;
        }
        if outcome == outcome_void() {
            refunds_total = refunds_total + p.cost_basis;
        } else if p.outcome == outcome {
            if p.qty > 0 {
                winners = winners + 1;
                payout_total = payout_total + (p.qty * redemption_v);
            }
        }
    }

    let fee_refunds_total = 0;
    if outcome == outcome_void() {
        for fo in fee_orders {
            fee_refunds_total = fee_refunds_total + fo.fee_amount;
        }
    }

    let collateral_released = 0;
    let treasury_delta = 0;
    let shortfall = 0;
    let needs_second_approval = false;

    if outcome == outcome_void() {
        collateral_released = initial_collateral;
        // treasury_delta = collateral_released - refunds_total
        treasury_delta = collateral_released - refunds_total;
        if refunds_total > collateral_released {
            shortfall = refunds_total - collateral_released;
        }
        if shortfall > shortfall_threshold {
            needs_second_approval = true;
        }
    } else {
        collateral_released = payout_total;
    }

    return SettlementPreview {
        outcome: outcome,
        winners: winners,
        payout_total: payout_total,
        burned_yes: burned_yes,
        burned_no: burned_no,
        collateral_released: collateral_released,
        refunds_total: refunds_total,
        fee_refunds_total: fee_refunds_total,
        treasury_delta: treasury_delta,
        shortfall: shortfall,
        needs_second_approval: needs_second_approval
    };
}

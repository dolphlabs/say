import "../../ledger/service" as ledger;
import "../domain" as domain;

pub fn build_yes_no_journal(
    market_id: str,
    decision_id: str,
    season_id: str,
    winning_outcome: str,
    redemption_v: int,
    positions: [domain.AccountPositionSnapshot]
) -> ledger.JournalBatch {
    let batch = ledger.journal_batch();
    let calculated = domain.calculate_yes_no_results(winning_outcome, redemption_v, positions);
    for item in calculated {
        let rows = ledger.journal_rows();
        let share_asset = "YES:" + market_id;
        if item.outcome == domain.outcome_no() {
            share_asset = "NO:" + market_id;
        }
        if item.qty > 0 {
            ledger.journal_entry(rows, "user", item.account_id, share_asset, "free", -item.qty, "");
            ledger.journal_entry(rows, "system", "system:shares:" + market_id, share_asset, "free", item.qty, "");
        }
        if item.paid_out > 0 {
            ledger.journal_entry(rows, "system", "system:collateral:" + market_id, "SEDI", "free", -item.paid_out, "");
            ledger.journal_entry(rows, "user", item.account_id, "SEDI", "free", item.paid_out, "");
        }
        if len(rows.entries) > 0 {
            ledger.journal_append(batch, rows, "settle:" + decision_id + ":" + item.account_id + ":" + item.outcome,
                                  "PAYOUT", season_id, market_id, "resolution_decision", decision_id);
        }
    }
    return batch;
}

pub fn build_void_journal(
    market_id: str,
    decision_id: str,
    season_id: str,
    positions: [domain.AccountPositionSnapshot],
    fee_orders: [domain.OrderFeeRefundItem]
) -> ledger.JournalBatch {
    let batch = ledger.journal_batch();
    let calculated = domain.calculate_void_results(positions, fee_orders);
    for item in calculated {
        let rows = ledger.journal_rows();
        let share_asset = "YES:" + market_id;
        if item.outcome == domain.outcome_no() {
            share_asset = "NO:" + market_id;
        }
        if item.qty > 0 {
            ledger.journal_entry(rows, "user", item.account_id, share_asset, "free", -item.qty, "");
            ledger.journal_entry(rows, "system", "system:shares:" + market_id, share_asset, "free", item.qty, "");
        }
        if item.cost_basis > 0 {
            ledger.journal_entry(rows, "system", "system:treasury", "SEDI", "free", -item.cost_basis, "");
            ledger.journal_entry(rows, "user", item.account_id, "SEDI", "free", item.cost_basis, "");
        }
        if len(rows.entries) > 0 {
            ledger.journal_append(batch, rows, "settle:" + decision_id + ":" + item.account_id + ":" + item.outcome,
                                  "VOID_REFUND", season_id, market_id, "resolution_decision", decision_id);
        }
    }
    return batch;
}

pub fn build_void_collateral_release(
    market_id: str,
    decision_id: str,
    season_id: str,
    collateral_balance: int
) -> ledger.JournalBatch {
    let batch = ledger.journal_batch();
    if collateral_balance > 0 {
        let rows = ledger.journal_rows();
        ledger.journal_entry(rows, "system", "system:collateral:" + market_id, "SEDI", "free", -collateral_balance, "");
        ledger.journal_entry(rows, "system", "system:treasury", "SEDI", "free", collateral_balance, "");
        ledger.journal_append(batch, rows, "void_collateral:" + decision_id,
                              "VOID_COLLATERAL_RELEASE", season_id, market_id, "resolution_decision", decision_id);
    }
    return batch;
}

pub fn build_void_fee_refunds(
    market_id: str,
    decision_id: str,
    season_id: str,
    fee_orders: [domain.OrderFeeRefundItem]
) -> ledger.JournalBatch {
    let batch = ledger.journal_batch();
    for fo in fee_orders {
        let rows = ledger.journal_rows();
        ledger.journal_entry(rows, "system", "system:fees", "SEDI", "free", -fo.fee_amount, "");
        ledger.journal_entry(rows, "user", fo.account_id, "SEDI", "free", fo.fee_amount, "");
        ledger.journal_append(batch, rows, "fee_refund:" + fo.order_id,
                              "FEE_REFUND", season_id, market_id, "resolution_decision", decision_id);
    }
    return batch;
}

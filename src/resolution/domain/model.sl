import "timez";

// Resolution state machine states
pub fn state_collecting() -> str { return "COLLECTING"; }
pub fn state_proposed() -> str { return "PROPOSED"; }
pub fn state_awaiting_final() -> str { return "AWAITING_FINAL"; }
pub fn state_held() -> str { return "HELD"; }
pub fn state_final() -> str { return "FINAL"; }

// Verdicts
pub fn verdict_says_yes() -> str { return "SAYS_YES"; }
pub fn verdict_says_no() -> str { return "SAYS_NO"; }
pub fn verdict_unclear() -> str { return "UNCLEAR"; }

// Outcomes
pub fn outcome_yes() -> str { return "YES"; }
pub fn outcome_no() -> str { return "NO"; }
pub fn outcome_void() -> str { return "VOID"; }

// Void reasons
pub fn void_postponed() -> str { return "POSTPONED"; }
pub fn void_abandoned() -> str { return "ABANDONED"; }
pub fn void_ambiguous() -> str { return "AMBIGUOUS"; }
pub fn void_source_unavailable() -> str { return "SOURCE_UNAVAILABLE"; }
pub fn void_other() -> str { return "OTHER"; }

// Dispute decisions
pub fn dispute_accept() -> str { return "ACCEPT"; }
pub fn dispute_reject() -> str { return "REJECT"; }

// Position result types
pub fn result_won() -> str { return "WON"; }
pub fn result_lost() -> str { return "LOST"; }
pub fn result_voided() -> str { return "VOIDED"; }

// Settlement job states
pub fn job_preparing() -> str { return "PREPARING"; }
pub fn job_waiting_close() -> str { return "WAITING_CLOSE"; }
pub fn job_waiting_approval() -> str { return "WAITING_APPROVAL"; }
pub fn job_running() -> str { return "RUNNING"; }
pub fn job_verifying() -> str { return "VERIFYING"; }
pub fn job_done() -> str { return "DONE"; }
pub fn job_invariant_failed() -> str { return "INVARIANT_FAILED"; }

// Void safeguard threshold in Sedis (S 50,000)
pub fn default_void_shortfall_threshold() -> int {
    return 50000;
}

// Dispute window duration in minutes (30 minutes)
pub fn dispute_window_duration_secs() -> int {
    return 30 * 60;
}

// Status note copy for cards
pub fn note_collecting() -> str { return "Collecting results"; }
pub fn note_proposed(outcome: str, mins_left: int) -> str {
    return "Settling · proposed " + outcome + " · " + to_str(mins_left) + "m to dispute";
}
pub fn note_under_review() -> str { return "Result under review"; }
pub fn note_settled_yes() -> str { return "Settled · Yes won"; }
pub fn note_settled_no() -> str { return "Settled · No won"; }
pub fn note_voided() -> str { return "Voided · refunds sent"; }

pub gc struct ResolutionEvidence {
    id: str,
    market_id: str,
    source_id: str,
    url: str,
    retrieved_at: timez.Time,
    http_status: int,
    content_type: str,
    snapshot_ref: str,
    sha256: str,
    finding: str,
    verdict: str,
    collected_by: str
}

pub gc struct ResolutionProposal {
    id: str,
    market_id: str,
    proposer_id: str,
    outcome: str,
    reason: str,
    evidence_ids: [str],
    proposed_at: timez.Time,
    dispute_until: timez.Time
}

pub gc struct ResolutionDispute {
    id: str,
    market_id: str,
    account_id: str,
    proposal_id: str,
    holdings_proof: str,
    reason: str,
    link_url: str,
    decision: str,
    decision_note: str,
    decided_by: str,
    decided_at: str,
    created_at: timez.Time
}

pub gc struct ResolutionDecision {
    id: str,
    market_id: str,
    season_id: str,
    outcome: str,
    void_reason: str,
    reason: str,
    proposer_id: str,
    finalizer_id: str,
    proposal_id: str,
    decided_at: timez.Time
}

pub gc struct ResolutionRecord {
    market_id: str,
    state: str,
    version: int,
    conflict: bool,
    overdue: bool,
    hold_reason: str,
    reason: str,
    current_proposal_id: str,
    final_decision_id: str,
    dispute_until: timez.Time,
    stage_label: str,
    updated_at: timez.Time
}

pub gc struct SettlementPreview {
    outcome: str,
    winners: int,
    payout_total: int,
    burned_yes: int,
    burned_no: int,
    collateral_released: int,
    refunds_total: int,
    fee_refunds_total: int,
    treasury_delta: int,
    shortfall: int,
    needs_second_approval: bool
}

pub gc struct SettlementJobRecord {
    id: str,
    market_id: str,
    decision_id: str,
    state: str,
    cursor: int,
    batch_size: int,
    done: bool,
    winners_count: int,
    payout_total: int,
    refunds_total: int,
    fee_refunds_total: int,
    collateral_released: int,
    treasury_delta: int,
    shortfall: int,
    error_message: str,
    started_at: timez.Time,
    finished_at: str
}

pub gc struct AccountPositionSnapshot {
    account_id: str,
    outcome: str,
    qty: int,
    cost_basis: int,
    fees_paid: int,
    realized_pnl: int
}

pub gc struct OrderFeeRefundItem {
    order_id: str,
    account_id: str,
    fee_amount: int
}

pub gc struct CalculatedResultItem {
    account_id: str,
    outcome: str,
    qty: int,
    cost_basis: int,
    fees: int,
    fees_refunded: int,
    paid_out: int,
    pnl: int,
    result_outcome: str
}

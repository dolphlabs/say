import "timez";
import "../domain" as domain;

pub gc struct Actor {
    id: str,
    roles: [str]
}

pub fn has_role(a: Actor, r: str) -> bool {
    for role in a.roles {
        if role == r || (r == "resolver" && role == "super_admin") {
            return true;
        }
    }
    return false;
}

pub gc struct QueueItem {
    market_id: str,
    slug: str,
    question: str,
    state: str,
    stage_label: str,
    meta: str,
    conflict: bool,
    overdue: bool
}

pub gc struct PublicEvidenceItem {
    source: str,
    finding: str,
    verdict: str,
    retrieved_at: str,
    snapshot_url: str,
    sha256: str
}

pub gc struct PublicResolution {
    state: str,
    proposed_outcome: str,
    dispute_until: str,
    evidence: [PublicEvidenceItem],
    final_outcome: str,
    final_reason: str,
    decided_at: str
}

pub gc struct ResolutionDetail {
    market_id: str,
    slug: str,
    question: str,
    state: str,
    version: int,
    conflict: bool,
    overdue: bool,
    dispute_until: str,
    proposed_outcome: str,
    proposed_reason: str,
    hold_reason: str,
    final_outcome: str,
    final_reason: str,
    decided_at: str,
    evidence: [domain.ResolutionEvidence],
    disputes: [domain.ResolutionDispute],
    preview: domain.SettlementPreview
}

pub gc struct SettlementProgress {
    market_id: str,
    decision_id: str,
    state: str,
    cursor: int,
    done: bool,
    winners_count: int,
    payout_total: int,
    refunds_total: int,
    fee_refunds_total: int,
    collateral_released: int,
    treasury_delta: int,
    shortfall: int,
    error_message: str
}

pub gc struct FinalizeResult {
    status: str,
    outcome: str,
    dispute_until: str,
    message: str
}

pub gc struct ParseResult {
    finding: str,
    verdict: str
}

pub gc struct MarketTermsBinding {
    question: str,
    yes_if: str,
    no_if: str
}

pub gc struct MarketInfoSqlRow {
    id: str,
    slug: str,
    question: str,
    season_id: str,
    status: str,
    redemption_units: int,
    resolve_by: opt[str],
    yes_if: opt[str],
    no_if: opt[str]
}

pub gc struct ResolutionStore[C] {
    context: C,
    ensure_resolution_initialized: fn(C, str) -> result[bool, str],
    query_queue: fn(C, str) -> result[[QueueItem], str],
    get_resolution_record: fn(C, str) -> result[domain.ResolutionRecord, str],
    query_evidence: fn(C, str) -> result[[domain.ResolutionEvidence], str],
    insert_evidence: fn(C, str, str, str, str, str, str, str) -> result[str, str],
    query_disputes: fn(C, str) -> result[[domain.ResolutionDispute], str],
    query_proposals: fn(C, str) -> result[[domain.ResolutionProposal], str],
    query_decision: fn(C, str) -> result[opt[domain.ResolutionDecision], str],
    get_market_info: fn(C, str) -> result[MarketInfoSqlRow, str],
    check_dispute_eligibility: fn(C, str, str) -> result[str, str],
    insert_dispute: fn(C, str, str, str, str, str, str) -> result[str, str],
    update_dispute_decision: fn(C, str, str, str, str, str) -> result[bool, str],
    insert_proposal: fn(C, str, str, str, str, [str], int) -> result[domain.ResolutionProposal, str],
    hold_resolution: fn(C, str, str, int) -> result[bool, str],
    insert_decision_and_resolve: fn(C, str, str, str, str, str, str, str, str, int) -> result[str, str],
    query_positions: fn(C, str) -> result[[domain.AccountPositionSnapshot], str],
    query_fee_orders: fn(C, str) -> result[[domain.OrderFeeRefundItem], str],
    query_settlement_job: fn(C, str) -> result[domain.SettlementJobRecord, str],
    get_market_collateral_balance: fn(C, str) -> result[int, str],
    execute_settlement_batch: fn(C, str, int) -> result[bool, str],
    tick_watchers: fn(C) -> result[[str], str]
}

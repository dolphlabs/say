import "crypto";
import "encoding";
import "timez";
import "../domain" as domain;

pub gc struct ResolutionService[C] {
    store: ResolutionStore[C]
}

pub fn new_resolution_service[C](s: ResolutionStore[C]) -> ResolutionService[C] {
    return ResolutionService[C] { store: s };
}

pub fn get_queue[C](svc: ResolutionService[C], state_filter: str) -> result[[QueueItem], str] {
    return (svc.store.query_queue)(svc.store.context, state_filter);
}

pub fn get_resolution_detail[C](svc: ResolutionService[C], market_id: str) -> result[ResolutionDetail, str] {
    let mr = (svc.store.get_market_info)(svc.store.context, market_id);
    guard let mkt = mr else let e = err_of(mr) { return err(e); }

    let rr = (svc.store.get_resolution_record)(svc.store.context, market_id);
    guard let res = rr else let e = err_of(rr) { return err(e); }

    let ev_r = (svc.store.query_evidence)(svc.store.context, market_id);
    let evidence: [domain.ResolutionEvidence] = [];
    if let ev = ev_r { evidence = ev; }

    let disp_r = (svc.store.query_disputes)(svc.store.context, market_id);
    let disputes: [domain.ResolutionDispute] = [];
    if let dp = disp_r { disputes = dp; }

    let prop_r = (svc.store.query_proposals)(svc.store.context, market_id);
    let proposed_outcome = "";
    let proposed_reason = "";
    if let props = prop_r {
        if len(props) > 0 {
            proposed_outcome = props[0].outcome;
            proposed_reason = props[0].reason;
        }
    }

    let dec_r = (svc.store.query_decision)(svc.store.context, market_id);
    let final_outcome = "";
    let final_reason = "";
    let decided_at_str = "";
    if let m_dec = dec_r {
        if let dec = m_dec {
            final_outcome = dec.outcome;
            final_reason = dec.reason;
            decided_at_str = dec.decided_at.rfc3339();
        }
    }

    // Build preview
    let positions_r = (svc.store.query_positions)(svc.store.context, market_id);
    let positions: [domain.AccountPositionSnapshot] = [];
    if let p = positions_r { positions = p; }

    let fee_orders_r = (svc.store.query_fee_orders)(svc.store.context, market_id);
    let fee_orders: [domain.OrderFeeRefundItem] = [];
    if let fo = fee_orders_r { fee_orders = fo; }

    let initial_collateral = 0;
    let cbr = (svc.store.get_market_collateral_balance)(svc.store.context, market_id);
    if let cb = cbr { initial_collateral = cb; }

    let preview_outcome = proposed_outcome;
    if len(final_outcome) > 0 {
        preview_outcome = final_outcome;
    }
    if len(preview_outcome) == 0 {
        preview_outcome = domain.outcome_yes();
    }

    let preview = domain.build_settlement_preview(
        preview_outcome,
        mkt.redemption_units,
        initial_collateral,
        positions,
        fee_orders,
        domain.default_void_shortfall_threshold()
    );

    return ok(ResolutionDetail {
        market_id: mkt.id,
        slug: mkt.slug,
        question: mkt.question,
        state: res.state,
        version: res.version,
        conflict: res.conflict,
        overdue: res.overdue,
        dispute_until: res.dispute_until.rfc3339(),
        proposed_outcome: proposed_outcome,
        proposed_reason: proposed_reason,
        hold_reason: res.hold_reason,
        final_outcome: final_outcome,
        final_reason: final_reason,
        decided_at: decided_at_str,
        evidence: evidence,
        disputes: disputes,
        preview: preview
    });
}

pub fn get_public_resolution[C](svc: ResolutionService[C], market_id: str) -> result[PublicResolution, str] {
    let rr = (svc.store.get_resolution_record)(svc.store.context, market_id);
    guard let res = rr else let e = err_of(rr) { return err(e); }

    let prop_r = (svc.store.query_proposals)(svc.store.context, market_id);
    let proposed_outcome = "";
    let dispute_until = "";
    if let props = prop_r {
        if len(props) > 0 {
            proposed_outcome = props[0].outcome;
            dispute_until = props[0].dispute_until.rfc3339();
        }
    }

    let ev_r = (svc.store.query_evidence)(svc.store.context, market_id);
    let evidence_items: [PublicEvidenceItem] = [];
    if let evidence = ev_r {
        for ev in evidence {
            push(evidence_items, PublicEvidenceItem {
                source: ev.source_id,
                finding: ev.finding,
                verdict: ev.verdict,
                retrieved_at: ev.retrieved_at.rfc3339(),
                snapshot_url: "/v1/markets/" + market_id + "/evidence/" + ev.id,
                sha256: ev.sha256
            });
        }
    }

    let dec_r = (svc.store.query_decision)(svc.store.context, market_id);
    let final_outcome = "";
    let final_reason = "";
    let decided_at_str = "";
    if let m_dec = dec_r {
        if let dec = m_dec {
            final_outcome = dec.outcome;
            final_reason = dec.reason;
            decided_at_str = dec.decided_at.rfc3339();
        }
    }

    return ok(PublicResolution {
        state: res.state,
        proposed_outcome: proposed_outcome,
        dispute_until: dispute_until,
        evidence: evidence_items,
        final_outcome: final_outcome,
        final_reason: final_reason,
        decided_at: decided_at_str
    });
}

pub fn add_evidence[C](
    svc: ResolutionService[C],
    market_id: str,
    url: str,
    note: str,
    actor: Actor
) -> result[str, str] {
    if !has_role(actor, "resolver") && !has_role(actor, "super_admin") {
        return err("FORBIDDEN");
    }
    let _ei = (svc.store.ensure_resolution_initialized)(svc.store.context, market_id);

    let mr = (svc.store.get_market_info)(svc.store.context, market_id);
    guard let mkt = mr else let e = err_of(mr) { return err(e); }

    let payload_to_hash = url + ":" + note;
    let sha = encoding.hex_encode(crypto.sha256(to_bytes(payload_to_hash)));

    let y_if = "";
    if let y = mkt.yes_if { y_if = y; }
    let n_if = "";
    if let n = mkt.no_if { n_if = n; }

    let binding = MarketTermsBinding {
        question: mkt.question,
        yes_if: y_if,
        no_if: n_if
    };
    let parsed = match_report_parse(note, binding);
    if parsed.verdict == domain.verdict_unclear() {
        parsed = generic_parse(note, binding);
    }

    let finding = parsed.finding;
    if len(note) > 0 {
        finding = note + " (" + parsed.finding + ")";
    }

    return (svc.store.insert_evidence)(
        svc.store.context,
        market_id,
        "manual",
        url,
        sha,
        finding,
        parsed.verdict,
        actor.id
    );
}

pub fn refresh_evidence[C](
    svc: ResolutionService[C],
    market_id: str,
    actor: Actor
) -> result[bool, str] {
    if !has_role(actor, "resolver") && !has_role(actor, "super_admin") {
        return err("FORBIDDEN");
    }
    let _ei = (svc.store.ensure_resolution_initialized)(svc.store.context, market_id);

    let mr = (svc.store.get_market_info)(svc.store.context, market_id);
    guard let mkt = mr else let e = err_of(mr) { return err(e); }

    let y_if = "";
    if let y = mkt.yes_if { y_if = y; }
    let n_if = "";
    if let n = mkt.no_if { n_if = n; }

    let binding = MarketTermsBinding {
        question: mkt.question,
        yes_if: y_if,
        no_if: n_if
    };

    let snapshot_content = "FT: " + mkt.question + " result captured at " + timez.now().rfc3339();
    let parsed = match_report_parse(snapshot_content, binding);
    let sha = encoding.hex_encode(crypto.sha256(to_bytes(snapshot_content)));

    let _ins = (svc.store.insert_evidence)(
        svc.store.context,
        market_id,
        "system_collector",
        "https://sports.example.com/match/" + mkt.slug,
        sha,
        parsed.finding,
        parsed.verdict,
        "system"
    );

    return ok(true);
}

pub fn propose[C](
    svc: ResolutionService[C],
    market_id: str,
    outcome: str,
    reason: str,
    evidence_ids: [str],
    version: int,
    actor: Actor
) -> result[bool, str] {
    if !has_role(actor, "resolver") && !has_role(actor, "super_admin") {
        return err("FORBIDDEN");
    }
    if outcome != domain.outcome_yes() && outcome != domain.outcome_no() {
        return err("INVALID_OUTCOME: must be YES or NO");
    }
    if len(evidence_ids) == 0 {
        return err("NO_EVIDENCE");
    }
    if len(reason) == 0 {
        return err("REASON_REQUIRED");
    }

    let _ei = (svc.store.ensure_resolution_initialized)(svc.store.context, market_id);
    let pr = (svc.store.insert_proposal)(svc.store.context, market_id, actor.id, outcome, reason, evidence_ids, version);
    guard let _prop = pr else let e = err_of(pr) { return err(e); }
    return ok(true);
}

pub fn hold[C](
    svc: ResolutionService[C],
    market_id: str,
    reason: str,
    version: int,
    actor: Actor
) -> result[bool, str] {
    if !has_role(actor, "resolver") && !has_role(actor, "super_admin") {
        return err("FORBIDDEN");
    }
    return (svc.store.hold_resolution)(svc.store.context, market_id, reason, version);
}

pub fn decide_dispute[C](
    svc: ResolutionService[C],
    market_id: str,
    dispute_id: str,
    decision: str,
    note: str,
    actor: Actor
) -> result[bool, str] {
    if !has_role(actor, "super_admin") {
        return err("NOT_SUPER_ADMIN");
    }
    if decision != domain.dispute_accept() && decision != domain.dispute_reject() {
        return err("INVALID_DECISION");
    }
    return (svc.store.update_dispute_decision)(svc.store.context, market_id, dispute_id, decision, note, actor.id);
}

pub fn dispute[C](
    svc: ResolutionService[C],
    market_id: str,
    reason: str,
    link_url: str,
    actor_id: str
) -> result[str, str] {
    if len(reason) < 20 || len(reason) > 500 {
        return err("INVALID_REASON_LENGTH: must be 20 to 500 characters");
    }

    let rr = (svc.store.get_resolution_record)(svc.store.context, market_id);
    guard let res = rr else let e = err_of(rr) { return err(e); }

    if res.state != domain.state_proposed() {
        return err("INVALID_STATE: market not in PROPOSED state");
    }
    if timez.now().after(res.dispute_until) {
        return err("DISPUTE_WINDOW_CLOSED");
    }

    let hr = (svc.store.check_dispute_eligibility)(svc.store.context, market_id, actor_id);
    guard let holdings_proof = hr else let e = err_of(hr) { return err(e); }

    return (svc.store.insert_dispute)(svc.store.context, market_id, actor_id, res.current_proposal_id, holdings_proof, reason, link_url);
}

pub fn finalize[C](
    svc: ResolutionService[C],
    market_id: str,
    outcome: str,
    void_reason: str,
    reason: str,
    version: int,
    actor: Actor
) -> result[FinalizeResult, str] {
    if !has_role(actor, "super_admin") {
        return err("NOT_SUPER_ADMIN");
    }

    let rr = (svc.store.get_resolution_record)(svc.store.context, market_id);
    guard let res = rr else let e = err_of(rr) { return err(e); }

    let mr = (svc.store.get_market_info)(svc.store.context, market_id);
    guard let mkt = mr else let e = err_of(mr) { return err(e); }

    let props_r = (svc.store.query_proposals)(svc.store.context, market_id);
    let cur_prop_outcome = "";
    let cur_proposer = "";
    let cur_prop_id = "";
    if let props = props_r {
        if len(props) > 0 {
            cur_prop_outcome = props[0].outcome;
            cur_proposer = props[0].proposer_id;
            cur_prop_id = props[0].id;
        }
    }

    // VOID handling
    if outcome == domain.outcome_void() {
        if len(void_reason) == 0 {
            return err("VOID_REASON_REQUIRED");
        }
        let positions_r = (svc.store.query_positions)(svc.store.context, market_id);
        let positions: [domain.AccountPositionSnapshot] = [];
        if let p = positions_r { positions = p; }

        let fee_orders_r = (svc.store.query_fee_orders)(svc.store.context, market_id);
        let fee_orders: [domain.OrderFeeRefundItem] = [];
        if let fo = fee_orders_r { fee_orders = fo; }

        let col_bal = 0;
        let cbr = (svc.store.get_market_collateral_balance)(svc.store.context, market_id);
        if let cb = cbr { col_bal = cb; }

        let preview = domain.build_settlement_preview(
            domain.outcome_void(),
            mkt.redemption_units,
            col_bal,
            positions,
            fee_orders,
            domain.default_void_shortfall_threshold()
        );

        if preview.needs_second_approval {
            return err("VOID_NEEDS_SECOND_APPROVAL");
        }

        let dec_r = (svc.store.insert_decision_and_resolve)(
            svc.store.context,
            market_id,
            mkt.season_id,
            domain.outcome_void(),
            void_reason,
            reason,
            cur_proposer,
            actor.id,
            cur_prop_id,
            version
        );
        guard let _dec_id = dec_r else let e = err_of(dec_r) { return err(e); }

        return ok(FinalizeResult {
            status: "FINALIZED",
            outcome: domain.outcome_void(),
            dispute_until: "",
            message: "Market voided and settlement initiated"
        });
    }

    // YES or NO finalizing:
    // If different outcome from proposal: triggers NEW proposal with a new 30-min window!
    if len(cur_prop_outcome) > 0 && outcome != cur_prop_outcome {
        let ev_ids: [str] = [];
        let ev_r = (svc.store.query_evidence)(svc.store.context, market_id);
        if let ev = ev_r {
            if len(ev) > 0 {
                push(ev_ids, ev[0].id);
            }
        }
        let prop_r = (svc.store.insert_proposal)(svc.store.context, market_id, actor.id, outcome, reason, ev_ids, version);
        guard let new_prop = prop_r else let e = err_of(prop_r) { return err(e); }

        return ok(FinalizeResult {
            status: "PROPOSED_RESET",
            outcome: outcome,
            dispute_until: new_prop.dispute_until.rfc3339(),
            message: "Outcome differed from proposal: started fresh 30-minute dispute window"
        });
    }

    // Guard: Window must be elapsed
    if timez.now().before(res.dispute_until) {
        return err("WINDOW_OPEN: dispute until " + res.dispute_until.rfc3339());
    }

    // Guard: Finalizer cannot be proposer
    if actor.id == cur_proposer {
        return err("PROPOSER_CANNOT_FINALIZE");
    }

    // Guard: No undecided disputes
    let disputes_r = (svc.store.query_disputes)(svc.store.context, market_id);
    if let disputes = disputes_r {
        for d in disputes {
            if len(d.decision) == 0 {
                return err("DISPUTES_UNDECIDED");
            }
        }
    }

    let dec_r = (svc.store.insert_decision_and_resolve)(
        svc.store.context,
        market_id,
        mkt.season_id,
        outcome,
        "",
        reason,
        cur_proposer,
        actor.id,
        cur_prop_id,
        version
    );
    guard let _dec_id = dec_r else let e = err_of(dec_r) { return err(e); }

    return ok(FinalizeResult {
        status: "FINALIZED",
        outcome: outcome,
        dispute_until: "",
        message: "Market resolved " + outcome + " and settlement initiated"
    });
}

pub fn get_settlement_progress[C](svc: ResolutionService[C], market_id: str) -> result[SettlementProgress, str] {
    let jr = (svc.store.query_settlement_job)(svc.store.context, market_id);
    guard let j = jr else let e = err_of(jr) { return err(e); }

    return ok(SettlementProgress {
        market_id: j.market_id,
        decision_id: j.decision_id,
        state: j.state,
        cursor: j.cursor,
        done: j.done,
        winners_count: j.winners_count,
        payout_total: j.payout_total,
        refunds_total: j.refunds_total,
        fee_refunds_total: j.fee_refunds_total,
        collateral_released: j.collateral_released,
        treasury_delta: j.treasury_delta,
        shortfall: j.shortfall,
        error_message: j.error_message
    });
}

pub fn run_settlement[C](svc: ResolutionService[C], market_id: str) -> result[bool, str] {
    return (svc.store.execute_settlement_batch)(svc.store.context, market_id, 500);
}

pub fn tick_watchers[C](svc: ResolutionService[C]) -> result[bool, str] {
    let r = (svc.store.tick_watchers)(svc.store.context);
    guard let pending_markets = r else let e = err_of(r) { return err(e); }
    for m_id in pending_markets {
        let _ = run_settlement(svc, m_id);
    }
    return ok(true);
}


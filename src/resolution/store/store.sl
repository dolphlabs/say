import "builder";
import "crypto";
import "encoding";
import "pg";
import "strings";
import "time";
import "timez";
import "zokor";
import "../../ledger/store" as ledger_store;
import "../domain" as domain;
import "../service" as service;

pub gc struct PostgresResolutionStore {
    pool: pg.Pool
}


fn parse_time(s: str) -> opt[timez.Time] {
    let none_t: opt[timez.Time] = none;
    let pr = timez.parse_rfc3339(s);
    if let t = pr { return some(t); }
    return none_t;
}

fn pg_deadline() -> until {
    return until_of(time.mono() + 10000000000); // 10s deadline
}

gc struct CountRow {
    n: int
}

gc struct StringRow {
    val: str
}

gc struct QueueSqlRow {
    market_id: str,
    slug: str,
    question: str,
    state: str,
    stage_label: str,
    conflict: bool,
    overdue: bool,
    dispute_until: opt[str],
    proposed_outcome: opt[str],
    disputes_count: int
}

gc struct EvidenceSqlRow {
    id: str,
    market_id: str,
    source_id: str,
    url: str,
    retrieved_at: str,
    http_status: int,
    content_type: str,
    snapshot_ref: str,
    sha256: str,
    finding: str,
    verdict: str,
    collected_by: str
}

gc struct ProposalSqlRow {
    id: str,
    market_id: str,
    proposer_id: str,
    outcome: str,
    reason: str,
    evidence_ids: str,
    proposed_at: str,
    dispute_until: str
}

gc struct DisputeSqlRow {
    id: str,
    market_id: str,
    account_id: str,
    proposal_id: opt[str],
    holdings_proof: str,
    reason: str,
    link_url: str,
    decision: opt[str],
    decision_note: str,
    decided_by: opt[str],
    decided_at: opt[str],
    created_at: str
}

gc struct DecisionSqlRow {
    id: str,
    market_id: str,
    season_id: str,
    outcome: str,
    void_reason: opt[str],
    reason: str,
    proposer_id: opt[str],
    finalizer_id: str,
    proposal_id: opt[str],
    decided_at: str
}

gc struct ResolutionSqlRow {
    market_id: str,
    state: str,
    version: int,
    conflict: bool,
    overdue: bool,
    hold_reason: str,
    reason: str,
    current_proposal_id: opt[str],
    final_decision_id: opt[str],
    dispute_until: opt[str],
    stage_label: str,
    updated_at: str
}

gc struct PositionSqlRow {
    account_id: str,
    outcome: str,
    qty: int,
    cost_basis: int,
    fees_paid: int,
    realized_pnl: int
}

gc struct FeeOrderSqlRow {
    order_id: str,
    account_id: str,
    fee_amount: int
}

gc struct SettlementJobSqlRow {
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
    error_message: opt[str],
    started_at: str,
    finished_at: opt[str]
}

pub fn ensure_resolution_initialized(s: PostgresResolutionStore, market_id: str) -> result[bool, str] {
    let d = pg_deadline();
    let r = pg.pool_query(s.pool,
        "insert into market_resolutions (market_id, state, version, stage_label) " +
        "values ($1::uuid, 'COLLECTING', 1, 'Collecting results') " +
        "on conflict (market_id) do nothing",
        [pg.arg_text(market_id)], d);
    guard let _ok = r else let e = err_of(r) { return err(e); }
    return ok(true);
}

pub fn query_queue(s: PostgresResolutionStore, state_filter: str) -> result[[service.QueueItem], str] {
    let d = pg_deadline();
    let args: [pg.Arg] = [pg.arg_text(state_filter)];
    let sql = "select m.id::text as market_id, m.slug, m.question, " +
              "coalesce(r.state, 'COLLECTING') as state, " +
              "coalesce(r.stage_label, 'Collecting results') as stage_label, " +
              "coalesce(r.conflict, false) as conflict, " +
              "case when coalesce(r.state, 'COLLECTING') = 'COLLECTING' and now() > m.resolve_by and r.current_proposal_id is null then true else coalesce(r.overdue, false) end as overdue, " +
              "r.dispute_until::text as dispute_until, p.outcome as proposed_outcome, " +
              "(select count(*)::bigint from resolution_disputes d where d.market_id = m.id)::int as disputes_count " +
              "from markets m " +
              "left join market_resolutions r on r.market_id = m.id " +
              "left join resolution_proposals p on p.id = r.current_proposal_id " +
              "where m.status in ('CLOSED', 'RESOLUTION_PENDING', 'SUSPENDED', 'RESOLVED', 'VOIDED', 'SETTLING') " +
              "and ($1 = '' or ($1 = 'OVERDUE' and (r.overdue = true or (coalesce(r.state, 'COLLECTING') = 'COLLECTING' and now() > m.resolve_by and r.current_proposal_id is null))) or ($1 <> 'OVERDUE' and coalesce(r.state, 'COLLECTING') = $1)) " +
              "order by m.close_at desc limit 100";

    let qr: result[[QueueSqlRow], str] = zokor.query_all(s.pool, sql, args, d);
    guard let rows = qr else let e = err_of(qr) { return err(e); }

    let items: [service.QueueItem] = [];
    for row in rows {
        let meta = "Collecting results";
        if row.state == domain.state_proposed() {
            let out = "Proposed";
            if let o = row.proposed_outcome {
                out = "Proposed " + o;
            }
            meta = out + " · " + to_str(row.disputes_count) + " dispute";
            if row.disputes_count != 1 {
                meta = meta + "s";
            }
        } else if row.state == domain.state_awaiting_final() {
            meta = "Dispute window closed · awaiting final approval";
        } else if row.state == domain.state_held() {
            meta = "Review paused";
        }

        push(items, service.QueueItem {
            market_id: row.market_id,
            slug: row.slug,
            question: row.question,
            state: row.state,
            stage_label: row.stage_label,
            meta: meta,
            conflict: row.conflict,
            overdue: row.overdue
        });
    }
    return ok(items);
}

pub fn get_resolution_record(s: PostgresResolutionStore, market_id: str) -> result[domain.ResolutionRecord, str] {
    let d = pg_deadline();
    let qr: result[[ResolutionSqlRow], str] = zokor.query_all(s.pool,
        "select market_id::text, state, version, conflict, overdue, hold_reason, reason, " +
        "current_proposal_id::text, final_decision_id::text, dispute_until::text, stage_label, updated_at::text " +
        "from market_resolutions where market_id = $1::uuid",
        [pg.arg_text(market_id)], d);
    guard let rows = qr else let e = err_of(qr) { return err(e); }
    if len(rows) == 0 {
        return ok(domain.ResolutionRecord {
            market_id: market_id,
            state: domain.state_collecting(),
            version: 1,
            conflict: false,
            overdue: false,
            hold_reason: "",
            reason: "",
            current_proposal_id: "",
            final_decision_id: "",
            dispute_until: timez.now(),
            stage_label: "Collecting results",
            updated_at: timez.now()
        });
    }
    let r = rows[0];
    let cur_prop = "";
    if let cp = r.current_proposal_id { cur_prop = cp; }
    let fin_dec = "";
    if let fd = r.final_decision_id { fin_dec = fd; }
    let d_until = timez.now();
    if let du = r.dispute_until {
        if let pt = parse_time(du) { d_until = pt; }
    }

    return ok(domain.ResolutionRecord {
        market_id: r.market_id,
        state: r.state,
        version: r.version,
        conflict: r.conflict,
        overdue: r.overdue,
        hold_reason: r.hold_reason,
        reason: r.reason,
        current_proposal_id: cur_prop,
        final_decision_id: fin_dec,
        dispute_until: d_until,
        stage_label: r.stage_label,
        updated_at: timez.now()
    });
}

pub fn query_evidence(s: PostgresResolutionStore, market_id: str) -> result[[domain.ResolutionEvidence], str] {
    let d = pg_deadline();
    let qr: result[[EvidenceSqlRow], str] = zokor.query_all(s.pool,
        "select id::text, market_id::text, source_id, url, retrieved_at::text, http_status, " +
        "content_type, snapshot_ref, sha256, finding, verdict, collected_by " +
        "from resolution_evidence where market_id = $1::uuid order by retrieved_at desc",
        [pg.arg_text(market_id)], d);
    guard let rows = qr else let e = err_of(qr) { return err(e); }
    let list: [domain.ResolutionEvidence] = [];
    for r in rows {
        let ret_at = timez.now();
        if let pt = parse_time(r.retrieved_at) { ret_at = pt; }
        push(list, domain.ResolutionEvidence {
            id: r.id,
            market_id: r.market_id,
            source_id: r.source_id,
            url: r.url,
            retrieved_at: ret_at,
            http_status: r.http_status,
            content_type: r.content_type,
            snapshot_ref: r.snapshot_ref,
            sha256: r.sha256,
            finding: r.finding,
            verdict: r.verdict,
            collected_by: r.collected_by
        });
    }
    return ok(list);
}

pub fn insert_evidence(
    s: PostgresResolutionStore,
    market_id: str,
    source_id: str,
    url: str,
    sha256: str,
    finding: str,
    verdict: str,
    collected_by: str
) -> result[str, str] {
    let d = pg_deadline();
    let ir: result[[StringRow], str] = zokor.query_all(s.pool,
        "insert into resolution_evidence (market_id, source_id, url, sha256, finding, verdict, collected_by) " +
        "values ($1::uuid, $2, $3, $4, $5, $6, $7) returning id::text as val",
        [pg.arg_text(market_id), pg.arg_text(source_id), pg.arg_text(url),
         pg.arg_text(sha256), pg.arg_text(finding), pg.arg_text(verdict), pg.arg_text(collected_by)], d);
    guard let rows = ir else let e = err_of(ir) { return err(e); }
    let ev_id = rows[0].val;

    let cr: result[[CountRow], str] = zokor.query_all(s.pool,
        "select count(distinct verdict)::bigint as n from resolution_evidence " +
        "where market_id = $1::uuid and verdict in ('SAYS_YES', 'SAYS_NO')",
        [pg.arg_text(market_id)], d);
    if let c_rows = cr {
        if c_rows[0].n >= 2 {
            let _u = pg.pool_query(s.pool,
                "update market_resolutions set conflict = true where market_id = $1::uuid",
                [pg.arg_text(market_id)], d);
        }
    }

    return ok(ev_id);
}

pub fn query_disputes(s: PostgresResolutionStore, market_id: str) -> result[[domain.ResolutionDispute], str] {
    let d = pg_deadline();
    let qr: result[[DisputeSqlRow], str] = zokor.query_all(s.pool,
        "select id::text, market_id::text, account_id::text, proposal_id::text, holdings_proof, " +
        "reason, link_url, decision, decision_note, decided_by::text, decided_at::text, created_at::text " +
        "from resolution_disputes where market_id = $1::uuid order by created_at asc",
        [pg.arg_text(market_id)], d);
    guard let rows = qr else let e = err_of(qr) { return err(e); }
    let list: [domain.ResolutionDispute] = [];
    for r in rows {
        let dec = "";
        if let d_str = r.decision { dec = d_str; }
        let dec_by = "";
        if let db = r.decided_by { dec_by = db; }
        let dec_at = "";
        if let da = r.decided_at { dec_at = da; }
        let prop_id = "";
        if let pi = r.proposal_id { prop_id = pi; }
        let cr_at = timez.now();
        if let pt = parse_time(r.created_at) { cr_at = pt; }

        push(list, domain.ResolutionDispute {
            id: r.id,
            market_id: r.market_id,
            account_id: r.account_id,
            proposal_id: prop_id,
            holdings_proof: r.holdings_proof,
            reason: r.reason,
            link_url: r.link_url,
            decision: dec,
            decision_note: r.decision_note,
            decided_by: dec_by,
            decided_at: dec_at,
            created_at: cr_at
        });
    }
    return ok(list);
}

pub fn query_proposals(s: PostgresResolutionStore, market_id: str) -> result[[domain.ResolutionProposal], str] {
    let d = pg_deadline();
    let qr: result[[ProposalSqlRow], str] = zokor.query_all(s.pool,
        "select id::text, market_id::text, proposer_id::text, outcome, reason, " +
        "array_to_string(evidence_ids, ',') as evidence_ids, proposed_at::text, dispute_until::text " +
        "from resolution_proposals where market_id = $1::uuid order by proposed_at desc",
        [pg.arg_text(market_id)], d);
    guard let rows = qr else let e = err_of(qr) { return err(e); }
    let list: [domain.ResolutionProposal] = [];
    for r in rows {
        let p_at = timez.now();
        if let pt = parse_time(r.proposed_at) { p_at = pt; }
        let d_un = timez.now();
        if let dt = parse_time(r.dispute_until) { d_un = dt; }

        let ev_ids: [str] = [];
        if len(r.evidence_ids) > 0 {
            ev_ids = strings.split(r.evidence_ids, ",");
        }

        push(list, domain.ResolutionProposal {
            id: r.id,
            market_id: r.market_id,
            proposer_id: r.proposer_id,
            outcome: r.outcome,
            reason: r.reason,
            evidence_ids: ev_ids,
            proposed_at: p_at,
            dispute_until: d_un
        });
    }
    return ok(list);
}

pub fn query_decision(s: PostgresResolutionStore, market_id: str) -> result[opt[domain.ResolutionDecision], str] {
    let d = pg_deadline();
    let qr: result[[DecisionSqlRow], str] = zokor.query_all(s.pool,
        "select id::text, market_id::text, season_id::text, outcome, void_reason, reason, " +
        "proposer_id::text, finalizer_id::text, proposal_id::text, decided_at::text " +
        "from resolution_decisions where market_id = $1::uuid",
        [pg.arg_text(market_id)], d);
    guard let rows = qr else let e = err_of(qr) { return err(e); }
    if len(rows) == 0 {
        return ok(none);
    }
    let r = rows[0];
    let vr = "";
    if let v = r.void_reason { vr = v; }
    let pr = "";
    if let p = r.proposer_id { pr = p; }
    let pi = "";
    if let p = r.proposal_id { pi = p; }
    let da = timez.now();
    if let pt = parse_time(r.decided_at) { da = pt; }

    return ok(some(domain.ResolutionDecision {
        id: r.id,
        market_id: r.market_id,
        season_id: r.season_id,
        outcome: r.outcome,
        void_reason: vr,
        reason: r.reason,
        proposer_id: pr,
        finalizer_id: r.finalizer_id,
        proposal_id: pi,
        decided_at: da
    }));
}

pub fn get_market_info(s: PostgresResolutionStore, market_id: str) -> result[service.MarketInfoSqlRow, str] {
    let d = pg_deadline();
    let qr: result[[service.MarketInfoSqlRow], str] = zokor.query_all(s.pool,
        "select m.id::text, m.slug, m.question, m.season_id::text, m.status, " +
        "coalesce(m.redemption_units, 100)::int as redemption_units, m.resolve_by::text, " +
        "coalesce(m.rules->>'yes_if', '') as yes_if, coalesce(m.rules->>'no_if', '') as no_if " +
        "from markets m where m.id = $1::uuid",
        [pg.arg_text(market_id)], d);
    guard let rows = qr else let e = err_of(qr) { return err(e); }
    if len(rows) == 0 { return err("NOT_FOUND"); }
    return ok(rows[0]);
}

pub fn check_dispute_eligibility(s: PostgresResolutionStore, market_id: str, account_id: str) -> result[str, str] {
    let d = pg_deadline();
    let dr: result[[CountRow], str] = zokor.query_all(s.pool,
        "select count(*)::bigint as n from resolution_disputes where market_id = $1::uuid and account_id = $2::uuid",
        [pg.arg_text(market_id), pg.arg_text(account_id)], d);
    guard let d_rows = dr else let e = err_of(dr) { return err(e); }
    if d_rows[0].n > 0 {
        return err("ALREADY_DISPUTED");
    }

    let pr: result[[PositionSqlRow], str] = zokor.query_all(s.pool,
        "select account_id::text, outcome, qty::int, cost_basis::int, fees_paid::int, realized_pnl::int " +
        "from positions where market_id = $1::uuid and account_id = $2::uuid",
        [pg.arg_text(market_id), pg.arg_text(account_id)], d);
    guard let p_rows = pr else let e = err_of(pr) { return err(e); }

    if len(p_rows) > 0 {
        let p = p_rows[0];
        if p.qty > 0 {
            return ok("holds " + to_str(p.qty) + " " + p.outcome);
        }
        return ok("previously held " + p.outcome);
    }

    let fr: result[[CountRow], str] = zokor.query_all(s.pool,
        "select count(*)::bigint as n from fills where market_id = $1::uuid and " +
        "(buyer_account_id = $2::uuid or seller_account_id = $2::uuid)",
        [pg.arg_text(market_id), pg.arg_text(account_id)], d);
    guard let f_rows = fr else let e = err_of(fr) { return err(e); }
    if f_rows[0].n > 0 {
        return ok("held shares via market fills");
    }

    return err("NOT_ELIGIBLE_TO_DISPUTE");
}

pub fn insert_dispute(
    s: PostgresResolutionStore,
    market_id: str,
    account_id: str,
    proposal_id: str,
    holdings_proof: str,
    reason: str,
    link_url: str
) -> result[str, str] {
    let d = pg_deadline();
    let ir: result[[StringRow], str] = zokor.query_all(s.pool,
        "insert into resolution_disputes (market_id, account_id, proposal_id, holdings_proof, reason, link_url) " +
        "values ($1::uuid, $2::uuid, $3::uuid, $4, $5, $6) returning id::text as val",
        [pg.arg_text(market_id), pg.arg_text(account_id), pg.arg_text(proposal_id),
         pg.arg_text(holdings_proof), pg.arg_text(reason), pg.arg_text(link_url)], d);
    guard let rows = ir else let e = err_of(ir) { return err(e); }
    let dispute_id = rows[0].val;

    let payload = zokor.jobj()
        .set_str("market_id", market_id)
        .set_str("dispute_id", dispute_id)
        .set_str("account_id", account_id)
        .set_str("holdings_proof", holdings_proof)
        .set_str("reason", reason);
    let _eo = pg.pool_query(s.pool,
        "insert into outbox_events (market_id, type, payload) values ($1::uuid, 'market.dispute_raised', $2::jsonb)",
        [pg.arg_text(market_id), pg.arg_text(payload.render())], d);

    return ok(dispute_id);
}

pub fn update_dispute_decision(
    s: PostgresResolutionStore,
    market_id: str,
    dispute_id: str,
    decision: str,
    note: str,
    decided_by: str
) -> result[bool, str] {
    let d = pg_deadline();
    let ur = pg.pool_query(s.pool,
        "update resolution_disputes set decision = $1, decision_note = $2, decided_by = $3::uuid, decided_at = now() " +
        "where id = $4::uuid and market_id = $5::uuid",
        [pg.arg_text(decision), pg.arg_text(note), pg.arg_text(decided_by),
         pg.arg_text(dispute_id), pg.arg_text(market_id)], d);
    guard let _ok = ur else let e = err_of(ur) { return err(e); }
    return ok(true);
}

pub fn insert_proposal(
    s: PostgresResolutionStore,
    market_id: str,
    proposer_id: str,
    outcome: str,
    reason: str,
    evidence_ids: [str],
    expected_version: int
) -> result[domain.ResolutionProposal, str] {
    let d = pg_deadline();

    let vr: result[[CountRow], str] = zokor.query_all(s.pool,
        "select count(*)::bigint as n from market_resolutions where market_id = $1::uuid and version = $2",
        [pg.arg_text(market_id), pg.arg_int(expected_version)], d);
    guard let v_rows = vr else let e = err_of(vr) { return err(e); }
    if v_rows[0].n == 0 {
        return err("STALE_VERSION");
    }

    let ir: result[[ProposalSqlRow], str] = zokor.query_all(s.pool,
        "insert into resolution_proposals (market_id, proposer_id, outcome, reason, evidence_ids, proposed_at, dispute_until) " +
        "values ($1::uuid, $2::uuid, $3, $4, $5::text[], now(), now() + interval '30 minutes') " +
        "returning id::text, market_id::text, proposer_id::text, outcome, reason, " +
        "array_to_string(evidence_ids, ',') as evidence_ids, proposed_at::text, dispute_until::text",
        [pg.arg_text(market_id), pg.arg_text(proposer_id), pg.arg_text(outcome),
         pg.arg_text(reason), pg.arg_text(ledger_store.text_array(evidence_ids))], d);
    guard let p_rows = ir else let e = err_of(ir) { return err(e); }
    let row = p_rows[0];

    let stage = domain.note_proposed(outcome, 30);
    let ur = pg.pool_query(s.pool,
        "update market_resolutions set state = 'PROPOSED', current_proposal_id = $1::uuid, " +
        "dispute_until = $2::timestamptz, stage_label = $3, version = version + 1, updated_at = now() " +
        "where market_id = $4::uuid and version = $5",
        [pg.arg_text(row.id), pg.arg_text(row.dispute_until), pg.arg_text(stage),
         pg.arg_text(market_id), pg.arg_int(expected_version)], d);
    guard let _ok = ur else let e = err_of(ur) { return err(e); }

    let _um = pg.pool_query(s.pool,
        "update markets set status_note = $1, status = 'RESOLUTION_PENDING' where id = $2::uuid",
        [pg.arg_text(stage), pg.arg_text(market_id)], d);

    let payload = zokor.jobj()
        .set_str("market_id", market_id)
        .set_str("proposal_id", row.id)
        .set_str("outcome", outcome)
        .set_str("reason", reason)
        .set_str("dispute_until", row.dispute_until);
    let _eo = pg.pool_query(s.pool,
        "insert into outbox_events (market_id, type, payload) values ($1::uuid, 'market.result_proposed', $2::jsonb)",
        [pg.arg_text(market_id), pg.arg_text(payload.render())], d);

    let p_at = timez.now();
    if let pt = parse_time(row.proposed_at) { p_at = pt; }
    let d_un = timez.now();
    if let dt = parse_time(row.dispute_until) { d_un = dt; }

    return ok(domain.ResolutionProposal {
        id: row.id,
        market_id: row.market_id,
        proposer_id: row.proposer_id,
        outcome: row.outcome,
        reason: row.reason,
        evidence_ids: evidence_ids,
        proposed_at: p_at,
        dispute_until: d_un
    });
}

pub fn hold_resolution(
    s: PostgresResolutionStore,
    market_id: str,
    reason: str,
    expected_version: int
) -> result[bool, str] {
    let d = pg_deadline();
    let stage = domain.note_under_review();
    let ur = pg.pool_query(s.pool,
        "update market_resolutions set state = 'HELD', hold_reason = $1, stage_label = $2, " +
        "version = version + 1, updated_at = now() " +
        "where market_id = $3::uuid and version = $4",
        [pg.arg_text(reason), pg.arg_text(stage), pg.arg_text(market_id), pg.arg_int(expected_version)], d);
    guard let _ok = ur else let e = err_of(ur) { return err(e); }

    let _um = pg.pool_query(s.pool,
        "update markets set status_note = $1 where id = $2::uuid",
        [pg.arg_text(stage), pg.arg_text(market_id)], d);

    return ok(true);
}

pub fn insert_decision_and_resolve(
    s: PostgresResolutionStore,
    market_id: str,
    season_id: str,
    outcome: str,
    void_reason: str,
    reason: str,
    proposer_id: str,
    finalizer_id: str,
    proposal_id: str,
    expected_version: int
) -> result[str, str] {
    let d = pg_deadline();

    let vr: result[[CountRow], str] = zokor.query_all(s.pool,
        "select count(*)::bigint as n from market_resolutions where market_id = $1::uuid and version = $2",
        [pg.arg_text(market_id), pg.arg_int(expected_version)], d);
    guard let v_rows = vr else let e = err_of(vr) { return err(e); }
    if v_rows[0].n == 0 {
        return err("STALE_VERSION");
    }

    let args: [pg.Arg] = [
        pg.arg_text(market_id),
        pg.arg_text(season_id),
        pg.arg_text(outcome),
        pg.arg_text(void_reason),
        pg.arg_text(reason),
        pg.arg_text(proposer_id),
        pg.arg_text(finalizer_id),
        pg.arg_text(proposal_id)
    ];

    let sql = "insert into resolution_decisions (market_id, season_id, outcome, void_reason, reason, proposer_id, finalizer_id, proposal_id) " +
              "values ($1::uuid, $2::uuid, $3, nullif($4, ''), $5, nullif($6, '')::uuid, $7::uuid, nullif($8, '')::uuid) " +
              "returning id::text as val";
    let ir: result[[StringRow], str] = zokor.query_all(s.pool, sql, args, d);
    guard let rows = ir else let e = err_of(ir) { return err(e); }
    let decision_id = rows[0].val;

    let market_status = "RESOLVED";
    let stage = "Settled · " + outcome + " won";
    let event_type = "market.resolved";
    if outcome == domain.outcome_void() {
        market_status = "VOIDED";
        stage = "Voided · refunds pending";
        event_type = "market.voided";
    }

    let _ur = pg.pool_query(s.pool,
        "update market_resolutions set state = 'FINAL', final_decision_id = $1::uuid, " +
        "stage_label = $2, version = version + 1, updated_at = now() where market_id = $3::uuid",
        [pg.arg_text(decision_id), pg.arg_text(stage), pg.arg_text(market_id)], d);

    let _um = pg.pool_query(s.pool,
        "update markets set status = $1, status_note = $2 where id = $3::uuid",
        [pg.arg_text(market_status), pg.arg_text(stage), pg.arg_text(market_id)], d);

    let _sj = pg.pool_query(s.pool,
        "insert into settlement_jobs (market_id, decision_id, state) " +
        "values ($1::uuid, $2::uuid, 'PREPARING') on conflict (market_id) do nothing",
        [pg.arg_text(market_id), pg.arg_text(decision_id)], d);

    let payload = zokor.jobj()
        .set_str("market_id", market_id)
        .set_str("decision_id", decision_id)
        .set_str("outcome", outcome)
        .set_str("reason", reason);
    let _eo = pg.pool_query(s.pool,
        "insert into outbox_events (market_id, type, payload) values ($1::uuid, $2, $3::jsonb)",
        [pg.arg_text(market_id), pg.arg_text(event_type), pg.arg_text(payload.render())], d);

    return ok(decision_id);
}

pub fn query_positions(s: PostgresResolutionStore, market_id: str) -> result[[domain.AccountPositionSnapshot], str] {
    let d = pg_deadline();
    let qr: result[[PositionSqlRow], str] = zokor.query_all(s.pool,
        "select account_id::text, outcome, qty::int, cost_basis::int, fees_paid::int, realized_pnl::int " +
        "from positions where market_id = $1::uuid and qty > 0 order by account_id, outcome",
        [pg.arg_text(market_id)], d);
    guard let rows = qr else let e = err_of(qr) { return err(e); }
    let list: [domain.AccountPositionSnapshot] = [];
    for r in rows {
        push(list, domain.AccountPositionSnapshot {
            account_id: r.account_id,
            outcome: r.outcome,
            qty: r.qty,
            cost_basis: r.cost_basis,
            fees_paid: r.fees_paid,
            realized_pnl: r.realized_pnl
        });
    }
    return ok(list);
}

pub fn query_fee_orders(s: PostgresResolutionStore, market_id: str) -> result[[domain.OrderFeeRefundItem], str] {
    let d = pg_deadline();
    let qr: result[[FeeOrderSqlRow], str] = zokor.query_all(s.pool,
        "select id::text as order_id, account_id::text, fee_units::int as fee_amount " +
        "from orders where market_id = $1::uuid and fee_units > 0",
        [pg.arg_text(market_id)], d);
    guard let rows = qr else let e = err_of(qr) { return err(e); }
    let list: [domain.OrderFeeRefundItem] = [];
    for r in rows {
        push(list, domain.OrderFeeRefundItem {
            order_id: r.order_id,
            account_id: r.account_id,
            fee_amount: r.fee_amount
        });
    }
    return ok(list);
}

pub fn query_settlement_job(s: PostgresResolutionStore, market_id: str) -> result[domain.SettlementJobRecord, str] {
    let d = pg_deadline();
    let qr: result[[SettlementJobSqlRow], str] = zokor.query_all(s.pool,
        "select id::text, market_id::text, decision_id::text, state, cursor, batch_size, done, " +
        "winners_count, payout_total::int, refunds_total::int, fee_refunds_total::int, " +
        "collateral_released::int, treasury_delta::int, shortfall::int, error_message, " +
        "started_at::text, finished_at::text from settlement_jobs where market_id = $1::uuid",
        [pg.arg_text(market_id)], d);
    guard let rows = qr else let e = err_of(qr) { return err(e); }
    if len(rows) == 0 { return err("NOT_FOUND"); }
    let r = rows[0];
    let err_msg = "";
    if let em = r.error_message { err_msg = em; }
    let fin_at = "";
    if let fa = r.finished_at { fin_at = fa; }
    let st_at = timez.now();
    if let pt = parse_time(r.started_at) { st_at = pt; }

    return ok(domain.SettlementJobRecord {
        id: r.id,
        market_id: r.market_id,
        decision_id: r.decision_id,
        state: r.state,
        cursor: r.cursor,
        batch_size: r.batch_size,
        done: r.done,
        winners_count: r.winners_count,
        payout_total: r.payout_total,
        refunds_total: r.refunds_total,
        fee_refunds_total: r.fee_refunds_total,
        collateral_released: r.collateral_released,
        treasury_delta: r.treasury_delta,
        shortfall: r.shortfall,
        error_message: err_msg,
        started_at: st_at,
        finished_at: fin_at
    });
}

pub fn get_market_collateral_balance(s: PostgresResolutionStore, market_id: str) -> result[int, str] {
    let d = pg_deadline();
    let qr: result[[CountRow], str] = zokor.query_all(s.pool,
        "select coalesce(sum(delta), 0)::bigint as n from ledger_entries e join wallets w on w.id = e.wallet_id where w.owner_id = 'system:collateral:' || $1 and w.asset_key = 'SEDI'",
        [pg.arg_text(market_id)], d);
    guard let rows = qr else let e = err_of(qr) { return err(e); }
    return ok(rows[0].n);
}

pub fn execute_settlement_batch(
    s: PostgresResolutionStore,
    market_id: str,
    batch_size: int
) -> result[bool, str] {
    let d = pg_deadline();

    let jr = query_settlement_job(s, market_id);
    guard let job = jr else let e = err_of(jr) { return err(e); }
    if job.done { return ok(true); }

    let dr = query_decision(s, market_id);
    guard let m_dec = dr else let e = err_of(dr) { return err(e); }
    guard let decision = m_dec else { return err("NO_DECISION"); }

    let mr = get_market_info(s, market_id);
    guard let mkt = mr else let e = err_of(mr) { return err(e); }

    let hr: result[[CountRow], str] = zokor.query_all(s.pool,
        "select count(*)::bigint as n from holds where market_id = $1::uuid and status = 'open'",
        [pg.arg_text(market_id)], d);
    guard let h_rows = hr else let e = err_of(hr) { return err(e); }
    if h_rows[0].n > 0 {
        let _u = pg.pool_query(s.pool, "update settlement_jobs set state = 'WAITING_CLOSE' where market_id = $1::uuid", [pg.arg_text(market_id)], d);
        return ok(false);
    }

    let or: result[[CountRow], str] = zokor.query_all(s.pool,
        "select count(*)::bigint as n from orders where market_id = $1::uuid and status in ('OPEN', 'PENDING')",
        [pg.arg_text(market_id)], d);
    guard let o_rows = or else let e = err_of(or) { return err(e); }
    if o_rows[0].n > 0 {
        let _u = pg.pool_query(s.pool, "update settlement_jobs set state = 'WAITING_CLOSE' where market_id = $1::uuid", [pg.arg_text(market_id)], d);
        return ok(false);
    }

    let _uj = pg.pool_query(s.pool, "update settlement_jobs set state = 'RUNNING' where market_id = $1::uuid and state in ('PREPARING', 'WAITING_CLOSE')", [pg.arg_text(market_id)], d);
    let _um = pg.pool_query(s.pool, "update markets set status = 'SETTLING' where id = $1::uuid and status in ('RESOLVED', 'VOIDED')", [pg.arg_text(market_id)], d);

    let pr: result[[PositionSqlRow], str] = zokor.query_all(s.pool,
        "select account_id::text, outcome, qty::int, cost_basis::int, fees_paid::int, realized_pnl::int " +
        "from positions where market_id = $1::uuid and qty > 0 " +
        "order by account_id, outcome limit $2 offset $3",
        [pg.arg_text(market_id), pg.arg_int(batch_size), pg.arg_int(job.cursor)], d);
    guard let p_rows = pr else let e = err_of(pr) { return err(e); }

    let positions: [domain.AccountPositionSnapshot] = [];
    for r in p_rows {
        push(positions, domain.AccountPositionSnapshot {
            account_id: r.account_id,
            outcome: r.outcome,
            qty: r.qty,
            cost_basis: r.cost_basis,
            fees_paid: r.fees_paid,
            realized_pnl: r.realized_pnl
        });
    }

    let cr = pg.acquire(s.pool, d);
    guard let conn = cr else let e = err_of(cr) { return err(e); }
    let _beg = pg.query(conn, "BEGIN", [], d);

    if decision.outcome == domain.outcome_void() {
        let fee_orders_r = query_fee_orders(s, market_id);
        let fee_orders: [domain.OrderFeeRefundItem] = [];
        if let fo = fee_orders_r { fee_orders = fo; }

        let batch = service.build_void_journal(market_id, decision.id, decision.season_id, positions, fee_orders);
        if len(batch.transactions) > 0 {
            let pr2 = ledger_store.post_many_encoded(conn, batch.transactions, d);
            guard let _posted = pr2 else let e = err_of(pr2) {
                let _rb = pg.query(conn, "ROLLBACK", [], d);
                pg.release(s.pool, conn);
                return err(e);
            }
        }

        let calculated = domain.calculate_void_results(positions, fee_orders);
        for item in calculated {
            let _wpr = pg.query(conn,
                "insert into position_results (account_id, market_id, season_id, outcome, qty, cost_basis, fees, paid_out, pnl, result, settled_at) " +
                "values ($1::uuid, $2::uuid, $3::uuid, $4, $5, $6, $7, $8, $9, $10, now()) " +
                "on conflict (account_id, market_id, season_id, outcome) do update " +
                "set qty = excluded.qty, cost_basis = excluded.cost_basis, fees = excluded.fees, paid_out = excluded.paid_out, pnl = excluded.pnl, result = excluded.result",
                [pg.arg_text(item.account_id), pg.arg_text(market_id), pg.arg_text(decision.season_id),
                 pg.arg_text(item.outcome), pg.arg_int(item.qty), pg.arg_int(item.cost_basis),
                 pg.arg_int(item.fees), pg.arg_int(item.paid_out), pg.arg_int(item.pnl), pg.arg_text(item.result_outcome)], d);
        }
    } else {
        let batch = service.build_yes_no_journal(market_id, decision.id, decision.season_id, decision.outcome, mkt.redemption_units, positions);
        if len(batch.transactions) > 0 {
            let pr2 = ledger_store.post_many_encoded(conn, batch.transactions, d);
            guard let _posted = pr2 else let e = err_of(pr2) {
                let _rb = pg.query(conn, "ROLLBACK", [], d);
                pg.release(s.pool, conn);
                return err(e);
            }
        }

        let calculated = domain.calculate_yes_no_results(decision.outcome, mkt.redemption_units, positions);
        for item in calculated {
            let _wpr = pg.query(conn,
                "insert into position_results (account_id, market_id, season_id, outcome, qty, cost_basis, fees, paid_out, pnl, result, settled_at) " +
                "values ($1::uuid, $2::uuid, $3::uuid, $4, $5, $6, $7, $8, $9, $10, now()) " +
                "on conflict (account_id, market_id, season_id, outcome) do update " +
                "set qty = excluded.qty, cost_basis = excluded.cost_basis, fees = excluded.fees, paid_out = excluded.paid_out, pnl = excluded.pnl, result = excluded.result",
                [pg.arg_text(item.account_id), pg.arg_text(market_id), pg.arg_text(decision.season_id),
                 pg.arg_text(item.outcome), pg.arg_int(item.qty), pg.arg_int(item.cost_basis),
                 pg.arg_int(item.fees), pg.arg_int(item.paid_out), pg.arg_int(item.pnl), pg.arg_text(item.result_outcome)], d);
        }
    }

    let _com = pg.query(conn, "COMMIT", [], d);
    pg.release(s.pool, conn);

    let new_cursor = job.cursor + len(positions);
    let is_last_batch = len(positions) < batch_size;

    if is_last_batch {
        if decision.outcome == domain.outcome_void() {
            let col_bal = 0;
            let cbr = get_market_collateral_balance(s, market_id);
            if let cb = cbr { col_bal = cb; }

            if col_bal > 0 {
                let col_batch = service.build_void_collateral_release(market_id, decision.id, decision.season_id, col_bal);
                let cr2 = pg.acquire(s.pool, d);
                if let c2 = cr2 {
                    let _b = pg.query(c2, "BEGIN", [], d);
                    let _p = ledger_store.post_many_encoded(c2, col_batch.transactions, d);
                    let _c = pg.query(c2, "COMMIT", [], d);
                    pg.release(s.pool, c2);
                }
            }

            let fee_orders_r = query_fee_orders(s, market_id);
            if let fee_orders = fee_orders_r {
                let fee_batch = service.build_void_fee_refunds(market_id, decision.id, decision.season_id, fee_orders);
                if len(fee_batch.transactions) > 0 {
                    let cr3 = pg.acquire(s.pool, d);
                    if let c3 = cr3 {
                        let _b = pg.query(c3, "BEGIN", [], d);
                        let _p = ledger_store.post_many_encoded(c3, fee_batch.transactions, d);
                        let _c = pg.query(c3, "COMMIT", [], d);
                        pg.release(s.pool, c3);
                    }
                }
            }
        }

        let col_after = 0;
        let cbr2 = get_market_collateral_balance(s, market_id);
        if let cb2 = cbr2 { col_after = cb2; }

        if col_after != 0 {
            let _h = pg.pool_query(s.pool, "update system_settings set trading_halted = true", [], d);
            let _uj = pg.pool_query(s.pool,
                "update settlement_jobs set state = 'INVARIANT_FAILED', error_message = 'Collateral balance non-zero after settlement' where market_id = $1::uuid",
                [pg.arg_text(market_id)], d);
            return err("INVARIANT_FAILED: collateral non-zero");
        }

        let _uj = pg.pool_query(s.pool,
            "update settlement_jobs set state = 'DONE', done = true, cursor = $1, finished_at = now() where market_id = $2::uuid",
            [pg.arg_int(new_cursor), pg.arg_text(market_id)], d);

        let final_note = "Settled · " + decision.outcome + " won";
        if decision.outcome == domain.outcome_void() {
            final_note = "Voided · refunds sent";
        }
        let _um = pg.pool_query(s.pool,
            "update markets set status = 'SETTLED', status_note = $1 where id = $2::uuid",
            [pg.arg_text(final_note), pg.arg_text(market_id)], d);

        let payload = zokor.jobj()
            .set_str("market_id", market_id)
            .set_str("decision_id", decision.id)
            .set_str("outcome", decision.outcome);
        let _eo = pg.pool_query(s.pool,
            "insert into outbox_events (market_id, type, payload) values ($1::uuid, 'market.settled', $2::jsonb)",
            [pg.arg_text(market_id), pg.arg_text(payload.render())], d);

        return ok(true);
    } else {
        let _uj = pg.pool_query(s.pool,
            "update settlement_jobs set cursor = $1 where market_id = $2::uuid",
            [pg.arg_int(new_cursor), pg.arg_text(market_id)], d);
        return ok(false);
    }
}

pub fn make_postgres_resolution_store(pool: pg.Pool) -> service.ResolutionStore[PostgresResolutionStore] {
    let s = PostgresResolutionStore { pool: pool };
    return service.ResolutionStore[PostgresResolutionStore] {
        context: s,
        ensure_resolution_initialized: ensure_resolution_initialized,
        query_queue: query_queue,
        get_resolution_record: get_resolution_record,
        query_evidence: query_evidence,
        insert_evidence: insert_evidence,
        query_disputes: query_disputes,
        query_proposals: query_proposals,
        query_decision: query_decision,
        get_market_info: get_market_info,
        check_dispute_eligibility: check_dispute_eligibility,
        insert_dispute: insert_dispute,
        update_dispute_decision: update_dispute_decision,
        insert_proposal: insert_proposal,
        hold_resolution: hold_resolution,
        insert_decision_and_resolve: insert_decision_and_resolve,
        query_positions: query_positions,
        query_fee_orders: query_fee_orders,
        query_settlement_job: query_settlement_job,
        get_market_collateral_balance: get_market_collateral_balance,
        execute_settlement_batch: execute_settlement_batch,
        tick_watchers: tick_watchers
    };
}

pub fn tick_watchers(s: PostgresResolutionStore) -> result[[str], str] {
    let d = pg_deadline();
    let none_args: [pg.Arg] = [];
    let _uw = pg.pool_query(s.pool,
        "update market_resolutions set state = 'AWAITING_FINAL', stage_label = 'Awaiting final approval' " +
        "where state = 'PROPOSED' and now() >= dispute_until", none_args, d);
    let _uo = pg.pool_query(s.pool,
        "update market_resolutions r set overdue = true " +
        "from markets m where m.id = r.market_id and r.state = 'COLLECTING' " +
        "and now() >= m.resolve_by and r.current_proposal_id is null and r.overdue = false", none_args, d);

    let jr: result[[StringRow], str] = zokor.query_all(s.pool,
        "select market_id::text as val from settlement_jobs where done = false and state in ('PREPARING', 'RUNNING') limit 4",
        none_args, d);
    guard let rows = jr else let e = err_of(jr) { return err(e); }
    let market_ids: [str] = [];
    for r in rows {
        push(market_ids, r.val);
    }
    return ok(market_ids);
}


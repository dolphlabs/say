import "../domain" as core;

pub fn prepare_replay(b: &core.Book, r: Record, w: &mut core.Workspace) -> str {
    if r.schema != "say.transition.v1" || r.supply_delta.yes != r.supply_delta.no { return "INVALID_TRANSITION"; }
    let fills: [core.Fill] = []; let updates: [core.Update] = []; let postings: [core.ReplayPosting] = [];
    for f in r.fills {
        if f.fill_index != len(fills) { return "INVALID_FILL"; }
        push(fills, core.Fill { mode: f.mode, maker_order_id: f.maker_order_id, taker_order_id: f.taker_order_id, qty: f.qty, yes_price: f.yes_price });
    }
    for u in r.order_updates {
        push(updates, core.Update { order: u.order, slot: -1, generation: 0, fee_charged_now: u.fee_charged_now, cancel_reason: u.cancel_reason, status: u.status });
    }
    for p in r.postings {
        if p.market_id != b.policy.market_id || p.season_id != b.policy.season_id || p.metadata != "{}" { return "INVALID_POSTING"; }
        let entries: [core.Entry] = []; let holds: [core.Hold] = [];
        for e in p.entries { push(entries, core.Entry { owner_kind: e.owner.kind, owner_id: e.owner.id, asset_key: e.asset_key, bucket: e.bucket, delta: e.delta, hold: e.hold }); }
        for h in p.holds { push(holds, core.Hold { op: h.op, hold_id: h.hold_id, owner_kind: h.owner.kind, owner_id: h.owner.id, asset_key: h.asset_key, amount: h.amount }); }
        push(postings, core.ReplayPosting { business_key: p.business_key, kind: p.kind, ref_type: p.ref_type, ref_id: p.ref_id, entries: entries, holds: holds });
    }
    let decided = core.Decided { market_id: r.market_id, season_id: r.season_id, base_seq: r.base_seq, seq: r.seq,
        prev_hash: r.prev_hash, state_hash: r.state_hash, command_ref: r.command_ref, command_kind: r.command_kind,
        decision: r.decision, mode: r.mode, fills: fills, updates: updates, postings: postings, supply_delta: r.supply_delta.yes,
        collateral_delta: r.collateral_delta, deltas: r.book_deltas, last_price: r.last_price ?? 0, full_state_hash: r.full_state_hash };
    let error = core.prepare_decided(b, decided, &mut *w);
    if error != "" { return error; }
    let canonical = record(b, &mut *w); guard let actual = canonical else let e = err_of(canonical) { w.ready = false; return e; }
    if !same_record(r, actual) { w.ready = false; return "INVALID_TRANSITION"; }
    return "";
}

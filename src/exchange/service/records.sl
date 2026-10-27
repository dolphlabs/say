import "../domain" as core;

pub gc struct Owner { kind: str, id: str }
pub gc struct Entry { owner: Owner, asset_key: str, bucket: str, delta: int, hold: str }
pub gc struct Hold { op: str, hold_id: str, owner: Owner, asset_key: str, amount: int }
pub gc struct Posting { business_key: str, kind: str, season_id: str, market_id: str, ref_type: str, ref_id: str, metadata: str, entries: [Entry], holds: [Hold] }
pub gc struct Fill { fill_index: int, mode: str, maker_order_id: str, taker_order_id: str, qty: int, yes_price: int }
pub gc struct Update { order: core.Order, status: str, fee_charged_now: bool, cancel_reason: str }
pub gc struct Supply { yes: int, no: int }
pub gc struct Trade { fill_index: int, yes_price: int, qty: int, aggressor: str }
pub gc struct Record {
    schema: str, market_id: str, season_id: str, base_seq: int, prev_hash: str, seq: int, command_ref: str, command_kind: str,
    decision: str, mode: str, fills: [Fill], order_updates: [Update], rested: opt[core.Order], postings: [Posting],
    supply_delta: Supply, collateral_delta: int, book_deltas: [core.LevelDelta], trades: [Trade], last_price: opt[int],
    state_hash: str, full_state_hash: opt[str],
}

pub fn record(b: &core.Book, w: &mut core.Workspace) -> result[Record, str] {
    if !w.ready { return err("NO_PLAN"); }
    let t = w.transition;
    let fills: [Fill] = []; let updates: [Update] = []; let postings: [Posting] = []; let levels: [core.LevelDelta] = []; let trades: [Trade] = [];
    for i in 0..t.fill_count {
        let f = w.fills[i];
        push(fills, Fill { fill_index: i, mode: f.mode, maker_order_id: f.maker_order_id, taker_order_id: f.taker_order_id, qty: f.qty, yes_price: f.yes_price });
        push(trades, Trade { fill_index: i, yes_price: f.yes_price, qty: f.qty, aggressor: core.book_side(w.updates[t.incoming_update].order) });
    }
    for i in 0..t.update_count {
        let u = w.updates[i]; push(updates, Update { order: u.order, status: u.status, fee_charged_now: u.fee_charged_now, cancel_reason: u.cancel_reason });
    }
    let keys = to_str(to_bytes(w.keys.data));
    for i in 0..t.posting_count {
        let p = w.postings[i]; let entries: [Entry] = []; let holds: [Hold] = [];
        for j in p.entry_start..(p.entry_start + p.entry_count) {
            let e = w.entries[j]; push(entries, Entry { owner: Owner { kind: e.owner_kind, id: e.owner_id }, asset_key: e.asset_key, bucket: e.bucket, delta: e.delta, hold: e.hold });
        }
        for j in p.hold_start..(p.hold_start + p.hold_count) {
            let h = w.holds[j]; push(holds, Hold { op: h.op, hold_id: h.hold_id, owner: Owner { kind: h.owner_kind, id: h.owner_id }, asset_key: h.asset_key, amount: h.amount });
        }
        push(postings, Posting { business_key: key_slice(keys, p.key_start, p.key_size), kind: p.kind, season_id: b.policy.season_id,
            market_id: b.policy.market_id, ref_type: p.ref_type, ref_id: p.ref_id, metadata: "{}", entries: entries, holds: holds });
    }
    for i in 0..t.delta_count { push(levels, w.deltas[i]); }
    let rested: opt[core.Order] = none; if t.rested_slot >= 0 { rested = some(w.updates[t.incoming_update].order); }
    let price: opt[int] = none; if t.last_price != 0 { price = some(t.last_price); }
    let full: opt[str] = none;
    if t.command_kind == "Snapshot" {
        let error = core.full_hash(b, true, &mut *w); if error != "" { return err(error); }
        full = some(core.digest_text(w.hashes.data, 64));
    }
    return ok(Record { schema: "say.transition.v1", market_id: b.policy.market_id, season_id: b.policy.season_id, base_seq: t.base_seq,
        prev_hash: core.digest_text(w.hashes.data, 0), seq: t.seq, command_ref: t.command_ref, command_kind: t.command_kind, decision: t.decision,
        mode: t.mode, fills: fills, order_updates: updates, rested: rested, postings: postings, supply_delta: Supply { yes: t.supply_delta, no: t.supply_delta },
        collateral_delta: t.collateral_delta, book_deltas: levels, trades: trades, last_price: price, state_hash: core.digest_text(w.hashes.data, 32), full_state_hash: full });
}

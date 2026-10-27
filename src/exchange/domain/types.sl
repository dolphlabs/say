pub struct Policy {
    market_id: str, season_id: str, V: int, min_price: int, max_price: int,
    tick: int, max_order_qty: int, min_order_notional: int,
}

pub struct Order {
    id: str, account_id: str, owner_kind: str, owner_group: str,
    outcome: str, side: str, limit: int, qty: int, remaining: int, tif: str,
    accepted_seq: int, fee_paid: bool, sedi_hold_id: str, share_hold_id: str,
    sedi_original: int, sedi_consumed: int, sedi_released: int,
    shares_original: int, shares_consumed: int, shares_released: int,
    filled: int, cancelled: int,
}

pub fn empty_order() -> Order {
    return Order { id: "", account_id: "", owner_kind: "", owner_group: "", outcome: "", side: "", limit: 0,
        qty: 0, remaining: 0, tif: "", accepted_seq: 0, fee_paid: false, sedi_hold_id: "", share_hold_id: "",
        sedi_original: 0, sedi_consumed: 0, sedi_released: 0, shares_original: 0, shares_consumed: 0,
        shares_released: 0, filled: 0, cancelled: 0 };
}

pub struct Command {
    kind: str, seq: int, ref: str, order: Order, order_id: str, account_id: str, system: bool, reason: str,
}

pub struct Level { head: int, tail: int, total: int }
pub struct Slot { order: Order, previous: int, next: int, generation: int, active: bool }
pub struct Bucket { slot: int, home: int }
pub struct Fill { mode: str, maker_order_id: str, taker_order_id: str, qty: int, yes_price: int }
pub struct Update { order: Order, slot: int, generation: int, fee_charged_now: bool, cancel_reason: str, status: str }
pub struct Entry { owner_kind: str, owner_id: str, asset_key: str, bucket: str, delta: int, hold: str }
pub struct Hold { op: str, hold_id: str, owner_kind: str, owner_id: str, asset_key: str, amount: int }
pub struct Posting {
    key_start: int, key_size: int, kind: str, ref_type: str, ref_id: str,
    entry_start: int, entry_count: int, hold_start: int, hold_count: int,
}
pub struct LevelDelta { side: str, yes_price: int, new_level_qty: int }

pub fn max_units() -> int { return 9223372036854775807; }

pub fn add_units(a: int, b: int) -> opt[int] {
    if b > 0 && a > max_units() - b { return none; }
    if b < 0 && a < (0 - max_units() - 1) - b { return none; }
    return some(a + b);
}

pub fn mul_units(a: int, b: int) -> opt[int] {
    if a < 0 || b < 0 { return none; }
    if a != 0 && b > max_units() / a { return none; }
    return some(a * b);
}

pub fn is_bid(o: Order) -> bool { return (o.side == "BUY") == (o.outcome == "YES"); }
pub fn yes_price(p: Policy, o: Order) -> int { if o.outcome == "YES" { return o.limit; } return p.V - o.limit; }
pub fn book_side(o: Order) -> str { if is_bid(o) { return "bid"; } return "ask"; }

pub fn canonical_uuid(value: str, scratch: wire) -> bool {
    if len(value) != 36 || len(scratch) < 36 { return false; }
    wire_put(scratch, 0, value);
    for i in 0..36 {
        let c = scratch[i];
        if i == 8 || i == 13 || i == 18 || i == 23 { if c != 45 { return false; } }
        else if !((c >= 48 && c <= 57) || (c >= 97 && c <= 102)) { return false; }
    }
    return true;
}

pub fn valid_policy(p: Policy, scratch: wire) -> bool {
    return canonical_uuid(p.market_id, scratch) && canonical_uuid(p.season_id, scratch) &&
        p.V >= 10 && p.V <= 1000 && p.min_price >= 1 && p.min_price <= p.max_price && p.max_price < p.V &&
        p.min_price + p.max_price == p.V && p.tick > 0 && p.min_price % p.tick == 0 &&
        (p.max_price - p.min_price) % p.tick == 0 && p.V % p.tick == 0 && p.max_order_qty > 0 && p.min_order_notional == 2;
}

pub gc struct ReplayPosting {
    business_key: str, kind: str, ref_type: str, ref_id: str, entries: [Entry], holds: [Hold],
}
pub gc struct Decided {
    market_id: str, season_id: str, base_seq: int, seq: int, prev_hash: str, state_hash: str,
    command_ref: str, command_kind: str, decision: str, mode: str, fills: [Fill], updates: [Update],
    postings: [ReplayPosting], supply_delta: int, collateral_delta: int, deltas: [LevelDelta],
    last_price: int, full_state_hash: opt[str],
}

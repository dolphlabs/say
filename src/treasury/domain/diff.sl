import "crypto";
import "encoding";
import "strings";

pub struct LiveOrder {
    id: str,
    outcome: str,
    side: str,
    price: int,
    qty: int
}

pub struct OrderDiff {
    to_cancel: [LiveOrder],
    to_place: [DesiredOrder],
    to_keep: [LiveOrder]
}

pub fn compute_order_diff(live: [LiveOrder], desired: [DesiredOrder]) -> OrderDiff {
    let to_cancel: [LiveOrder] = [];
    let to_place: [DesiredOrder] = [];
    let to_keep: [LiveOrder] = [];

    let matched_live: map[str]bool = {};

    for d in desired {
        let matched = false;
        for l in live {
            if !has(matched_live, l.id) {
                if l.outcome == d.outcome && l.side == d.side && l.price == d.price {
                    // Check 20% tolerance: |live.qty - desired.qty| / desired.qty <= 0.20
                    let diff_qty = abs_int(l.qty - d.qty);
                    if d.qty > 0 && (diff_qty * 100) <= (d.qty * 20) {
                        matched = true;
                        matched_live[l.id] = true;
                        push(to_keep, l);
                        break;
                    }
                }
            }
        }
        if !matched {
            push(to_place, d);
        }
    }

    for l in live {
        if !has(matched_live, l.id) {
            push(to_cancel, l);
        }
    }

    return OrderDiff {
        to_cancel: to_cancel,
        to_place: to_place,
        to_keep: to_keep
    };
}

pub fn make_idempotency_key(bot_id: str, market_id: str, level: int, price: int, qty: int) -> str {
    let data = bot_id + ":" + market_id + ":" + to_str(level) + ":" + to_str(price) + ":" + to_str(qty);
    let h = encoding.hex_encode(crypto.sha256(to_bytes(data)));
    return "bot:" + strings.slice(h, 0, 16);
}

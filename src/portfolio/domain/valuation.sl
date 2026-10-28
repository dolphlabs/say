// Valuation rules implementation for say portfolio per Prompt 07 section 1.

pub gc struct Rational {
    num: int,
    den: int
}

pub gc struct MarkResult {
    mark: Rational,
    source: str
}

pub gc struct PositionValuation {
    mark: Rational,
    mark_source: str,
    value: int,
    unrealized_pnl: int,
    pnl_pct: int,
    has_pnl_pct: bool
}

pub gc struct SummaryValuation {
    total: int,
    season_pnl: int,
    has_season_pnl: bool
}

pub fn gcd(a: int, b: int) -> int {
    let x = a;
    if x < 0 { x = -x; }
    let y = b;
    if y < 0 { y = -y; }
    while y > 0 {
        let t = y;
        y = x % y;
        x = t;
    }
    return x;
}

pub fn compute_mark(
    redemption_units: int,
    outcome: str,
    cost_basis: int,
    qty: int,
    last_price: int,
    has_last_price: bool,
    best_bid: int,
    has_best_bid: bool,
    best_ask: int,
    has_best_ask: bool
) -> MarkResult {
    if has_last_price {
        let own_price = last_price;
        if outcome != "YES" {
            own_price = redemption_units - last_price;
        }
        return MarkResult {
            mark: Rational { num: own_price, den: 1 },
            source: "last_trade"
        };
    }

    if has_best_bid && has_best_ask {
        let own_bid = best_bid;
        let own_ask = best_ask;
        if outcome != "YES" {
            own_bid = redemption_units - best_ask;
            own_ask = redemption_units - best_bid;
        }
        let mid = (own_bid + own_ask) / 2;
        return MarkResult {
            mark: Rational { num: mid, den: 1 },
            source: "mid"
        };
    }

    if qty > 0 {
        let g = gcd(cost_basis, qty);
        if g <= 0 { g = 1; }
        return MarkResult {
            mark: Rational { num: cost_basis / g, den: qty / g },
            source: "avg_cost"
        };
    }

    return MarkResult {
        mark: Rational { num: 0, den: 1 },
        source: "avg_cost"
    };
}

pub fn compute_position_valuation(
    redemption_units: int,
    outcome: str,
    qty: int,
    cost_basis: int,
    last_price: int,
    has_last_price: bool,
    best_bid: int,
    has_best_bid: bool,
    best_ask: int,
    has_best_ask: bool
) -> PositionValuation {
    let m = compute_mark(
        redemption_units, outcome, cost_basis, qty,
        last_price, has_last_price, best_bid, has_best_bid, best_ask, has_best_ask
    );

    let val = 0;
    if m.source == "avg_cost" && m.mark.den == qty && qty > 0 {
        val = cost_basis;
    } else {
        if m.mark.den > 0 {
            val = (qty * m.mark.num) / m.mark.den;
        }
    }

    let unrealized = val - cost_basis;
    let pnl_pct = 0;
    let has_pct = false;
    if cost_basis > 0 {
        pnl_pct = (100 * unrealized) / cost_basis;
        has_pct = true;
    }

    return PositionValuation {
        mark: m.mark,
        mark_source: m.source,
        value: val,
        unrealized_pnl: unrealized,
        pnl_pct: pnl_pct,
        has_pnl_pct: has_pct
    };
}

pub fn compute_summary_valuation(
    available: int,
    held: int,
    positions_value: int,
    starting_grant: int,
    has_starting_grant: bool
) -> SummaryValuation {
    let tot = available + held + positions_value;
    let pnl = 0;
    if has_starting_grant {
        pnl = tot - starting_grant;
    }
    return SummaryValuation {
        total: tot,
        season_pnl: pnl,
        has_season_pnl: has_starting_grant
    };
}

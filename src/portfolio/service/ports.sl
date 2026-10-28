import "../domain" as domain;

pub gc struct RawBalance {
    season_ordinal: int,
    season_status: str,
    ends_at: str,
    available: int,
    held: int,
    starting_grant: int,
    has_starting_grant: bool
}

pub gc struct RawHeldShare {
    market_id: str,
    outcome: str,
    qty: int
}

pub gc struct RawPosition {
    market_id: str,
    slug: str,
    question: str,
    category: str,
    status: str,
    closes_at: str,
    redemption_units: int,
    outcome: str,
    qty: int,
    qty_free: int,
    qty_in_orders: int,
    cost_basis: int,
    proposed_outcome: str,
    has_proposed_outcome: bool
}

pub gc struct RawResult {
    market_id: str,
    slug: str,
    question: str,
    category: str,
    status: str,
    closes_at: str,
    redemption_units: int,
    outcome: str,
    qty: int,
    cost_basis: int,
    fees: int,
    paid_out: int,
    pnl: int,
    result_outcome: str,
    settled_at: str
}

pub gc struct PortfolioStore[C] {
    context: C,
    read_balance: fn(C, str, int) -> result[RawBalance, str],
    read_held_shares: fn(C, str, int) -> result[[RawHeldShare], str],
    read_positions: fn(C, str, int) -> result[[RawPosition], str],
    read_results: fn(C, str, int) -> result[[RawResult], str]
}

pub gc struct MarketPriceStats {
    last_price: int,
    has_last_price: bool,
    best_bid: int,
    has_best_bid: bool,
    best_ask: int,
    has_best_ask: bool
}

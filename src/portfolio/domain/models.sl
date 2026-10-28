pub gc struct SeasonInfo {
    ordinal: int,
    status: str,
    ends_at: str
}

pub gc struct HeldShare {
    market_id: str,
    outcome: str,
    qty: int
}

pub gc struct RankInfo {
    position: int,
    of_total: int
}

pub gc struct SummaryView {
    season: SeasonInfo,
    available: int,
    held: int,
    held_shares: [HeldShare],
    positions_value: int,
    total: int,
    season_pnl: int,
    has_season_pnl: bool,
    starting_grant: int,
    has_starting_grant: bool,
    rank_position: int,
    rank_of: int,
    has_rank: bool
}

pub gc struct MarketInfo {
    id: str,
    slug: str,
    question: str,
    category: str,
    status: str,
    closes_at: str,
    redemption_units: int
}

pub gc struct PositionView {
    market: MarketInfo,
    outcome: str,
    qty: int,
    qty_free: int,
    qty_in_orders: int,
    avg_price: Rational,
    mark: Rational,
    mark_source: str,
    value: int,
    unrealized_pnl: int,
    pnl_pct: int,
    has_pnl_pct: bool,
    proposed_outcome: str,
    has_proposed_outcome: bool
}

pub gc struct ResultView {
    market: MarketInfo,
    outcome: str,
    qty: int,
    avg_price: Rational,
    result_outcome: str,
    paid_out: int,
    pnl: int,
    settled_at: str
}

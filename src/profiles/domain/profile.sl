pub gc struct MarketSummary {
    slug: str,
    question: str
}

pub gc struct CallItem {
    market: MarketSummary,
    side: str,
    status: str,
    chance_pct: opt[int]
}

pub gc struct CurrentSeasonStats {
    rank: int,
    of: int,
    profit: int,
    calls: int,
    right: int,
    settled: int
}

pub gc struct Profile {
    username: str,
    avatar_color: str,
    joined_season: str,
    share_url: str,
    current_season: CurrentSeasonStats,
    calls: [CallItem]
}

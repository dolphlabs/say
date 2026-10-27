import "../domain" as domain;

pub gc struct Failed { code: str, problems: [domain.Problem], detail: str }

pub fn failure(code: str, detail: str) -> Failed {
    let problems: [domain.Problem] = [];
    return Failed { code: code, problems: problems, detail: detail };
}

pub gc struct Command {
    action: str, id: str, actor_id: str, version: int,
    patch: domain.Patch, reason: str, now: int
}

pub gc struct Category { id: str, name: str, icon: str, sort_order: int }
pub gc struct Source { id: str, name: str, url_pattern: str, kind: str, approved: bool }
pub gc struct Stats {
    market_id: str, last_price: opt[int], yes_bid: opt[int], yes_ask: opt[int],
    no_bid: opt[int], no_ask: opt[int], volume_units: opt[int], volume_24h_units: opt[int],
    players: opt[int], change_24h: opt[str]
}
pub gc struct Season { id: str, ordinal: int, status: str, starts_at: int, ends_at: int }
pub gc struct Snapshot {
    markets: [domain.Market], categories: [Category], sources: [Source], stats: [Stats], seasons: [Season],
    generation: int, built_at: int,
    by_id: map[str]domain.Market, by_slug: map[str]domain.Market, stats_by_market: map[str]Stats,
    ordered_new: [domain.Market], ordered_ending: [domain.Market], ordered_trending: [domain.Market],
    pages: map[str][domain.Market]
}
pub gc struct MarketStore[C] {
    context: C,
    mutate: fn(C, Command) -> result[domain.Market, Failed],
    find: fn(C, str, str) -> result[opt[domain.Market], Failed],
    snapshot: fn(C, int) -> result[Snapshot, str],
    due: fn(C, int) -> result[[domain.Market], str],
    history: fn(C, str, str) -> result[str, Failed],
    source_create: fn(C, str, str, str, str, int) -> result[Source, Failed],
    lease_try: fn(C, int) -> result[opt[int], str],
    lease_release: fn(C, int),
    validate: fn(C, domain.Market, bool, int) -> result[[domain.Problem], Failed]
}

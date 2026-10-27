pub gc struct MarketLease {
    market_id: str,
    renewed: bool
}

pub gc struct Heartbeat {
    node_live: bool,
    markets: [MarketLease]
}

pub gc struct Claim {
    market_id: str,
    node_id: str,
    epoch: int,
    acquired: bool,
    renewed: bool
}

pub gc struct OwnershipStore[C] {
    context: C,
    register_node: fn(C, str, str, int) -> result[bool, str],
    heartbeat: fn(C, str, int, [str], [int]) -> result[Heartbeat, str],
    acquire: fn(C, str, str, int) -> result[Claim, str],
    release: fn(C, str, str, int) -> result[bool, str]
}

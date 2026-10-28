import "../domain" as domain;

pub gc struct StreamMessage {
    id: str,
    stream: str,
    event_id: str,
    market_id: str,
    account_id: str,
    audience: str,
    market_seq: int,
    event_ordinal: int,
    owner_epoch: int,
    msg_type: str,
    payload: str
}

pub gc struct SessionRevocation {
    id: str,
    session_id: str
}

pub gc struct RuntimeBookSnapshot {
    market_id: str,
    owner_epoch: int,
    committed_seq: int,
    book_seq: int,
    value: int,
    min_price: int,
    max_price: int,
    tick: int,
    health: str,
    mode: str,
    bids: [domain.Level],
    asks: [domain.Level]
}

pub gc struct CardStatItem {
    market_id: str,
    last_price: int,
    chance_pct: int,
    yes_ask: int,
    no_ask: int,
    volume_units: int,
    change_24h: int
}

pub gc struct StreamStore[C] {
    context: C,
    read_market_stream: fn(C, str, str, int, int) -> result[[StreamMessage], str],
    read_shard_stream: fn(C, int, str, int, int) -> result[[StreamMessage], str],
    read_session_revocations: fn(C, str, int, int) -> result[[SessionRevocation], str],
    get_book_view: fn(C, str) -> result[opt[RuntimeBookSnapshot], str],
    get_market_stats: fn(C) -> result[[CardStatItem], str],
    is_session_valid: fn(C, str) -> result[bool, str]
}

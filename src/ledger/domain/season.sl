import "timez";

pub gc struct Season {
    id: str,
    ordinal: int,
    starts_at: timez.Time,
    ends_at: timez.Time,
    status: str
}

pub gc struct Grant {
    amount: int,
    season_ordinal: int,
    season_ends_at: timez.Time
}

pub fn sedi() -> str {
    return "SEDI";
}

// Seeded by migration 003; the only wallet owner allowed below zero.
pub fn issuance_account_id() -> str {
    return "00000000-0000-4000-8000-000000000001";
}

// One grant per account per season, whatever retries or races happen.
pub fn grant_business_key(season_id: str, account_id: str) -> str {
    return "grant:" + season_id + ":" + account_id;
}

pub fn grant_problem(amount: int) -> opt[str] {
    if amount <= 0 {
        return some("grant amount must be positive");
    }
    return none;
}

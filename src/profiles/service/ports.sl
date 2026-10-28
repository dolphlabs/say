import "../domain" as domain;

pub gc struct AccountLookup {
    found: bool,
    redirect_username: str,
    account_id: str,
    username: str,
    avatar_color: str,
    status: str,
    created_at_ms: int
}

pub gc struct ProfileStore[C] {
    context: C,
    find_user: fn(C, str) -> result[AccountLookup, str],
    load_profile_calls: fn(C, str) -> result[[domain.CallItem], str],
    load_current_stats: fn(C, str) -> result[domain.CurrentSeasonStats, str]
}

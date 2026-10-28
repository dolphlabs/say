pub fn required_votes(kind: str) -> int {
    if kind == "issuance_policy" || kind == "bot_season_budget" || kind == "void_shortfall" { return 2; }
    return 1;
}

pub fn allowed_role(kind: str, roles: [str]) -> bool {
    for role in roles {
        if role == "super_admin" { return true; }
        if kind == "market_open" && role == "curator" { return true; }
        if (kind == "liquidity" || kind == "bot_topup" || kind == "bot_season_budget") && role == "treasury" { return true; }
    }
    return false;
}

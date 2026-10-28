fn test_approval_thresholds_and_scopes() {
    assert(required_votes("issuance_policy") == 2 && required_votes("bot_season_budget") == 2 && required_votes("void_shortfall") == 2);
    assert(required_votes("market_open") == 1);
    assert(!allowed_role("liquidity", ["admin", "curator"]));
    assert(allowed_role("market_open", ["curator"]));
    assert(allowed_role("void_shortfall", ["super_admin"]));
}

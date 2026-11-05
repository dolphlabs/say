fn test_should_change_the_top_up_hash_when_any_term_changes() {
    let base = topup_hash("t", "b", "m", 100);
    assert(len(base) == 64);
    assert(base == topup_hash("t", "b", "m", 100));
    assert(base != topup_hash("t", "b", "m", 101));
    assert(base != topup_hash("t", "x", "m", 100));
    assert(season_budget_hash("b", "s", 5) != season_budget_hash("b", "s", 6));
}

fn test_should_accept_only_simple_bot_usernames() {
    assert(valid_bot_username("mm_football_01"));
    assert(!valid_bot_username("mm"));
    assert(!valid_bot_username("MM_Football"));
    assert(!valid_bot_username("mm-football"));
    assert(!valid_bot_username("a_name_that_is_far_too_long_for_a_bot"));
}

fn test_should_accept_only_uuid_shaped_ids() {
    assert(valid_id("3b23c674-10cb-4f5b-8bcb-22e580fca16d"));
    assert(valid_id("3B23C674-10CB-4F5B-8BCB-22E580FCA16D"));
    assert(!valid_id("say_bot_000000000000000000000000000000000000000000000000"));
    assert(!valid_id("3b23c674-10cb-4f5b-8bcb-22e580fca16"));
    assert(!valid_id("3b23c674x10cb-4f5b-8bcb-22e580fca16d"));
    assert(!valid_id("3b23c674-10cb-4f5b-8bcb-22e580fca16g"));
    assert(!valid_id(""));
}

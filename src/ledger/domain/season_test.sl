fn test_should_key_grants_by_season_and_account() {
    assert(grant_business_key("s1", "a1") == "grant:s1:a1");
    assert(grant_business_key("s1", "a1") != grant_business_key("s2", "a1"));
}

fn test_should_reject_non_positive_grants() {
    if let _p = grant_problem(1000) {
        panic("1000 rejected");
    }
    guard let _zero = grant_problem(0) else {
        panic("0 accepted");
    }
}

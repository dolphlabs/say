fn test_effective_owner_group_falls_back_to_id() {
    let none_str: opt[str] = none;
    let a1 = Account {
        id: "acc_1",
        username: some("trader_joe"),
        email: some("test@example.com"),
        phone_number: some("+2348012345678"),
        password_hash: none_str,
        auth_provider: "LOCAL",
        status: "ACTIVE",
        kind: "USER",
        beneficial_owner_group: none_str,
        email_verified_at: none_str,
        verified_at: none_str,
        age_confirmed_at: none_str,
        created_at: "2026-10-16T12:00:00Z"
    };
    assert(effective_owner_group(a1) == "acc_1");

    let a2 = Account {
        id: "acc_2",
        username: some("bot_treas"),
        email: some("bot@example.com"),
        phone_number: none_str,
        password_hash: none_str,
        auth_provider: "SYSTEM",
        status: "ACTIVE",
        kind: "TREASURY",
        beneficial_owner_group: some("group_bots"),
        email_verified_at: none_str,
        verified_at: none_str,
        age_confirmed_at: none_str,
        created_at: "2026-10-16T12:00:00Z"
    };
    assert(effective_owner_group(a2) == "group_bots");
}

fn test_grant_eligibility_requires_active_verified_age_and_user_kind() {
    let none_str: opt[str] = none;
    let a = Account {
        id: "acc_user",
        username: some("trader_one"),
        email: some("trader@say.exchange"),
        phone_number: some("+2349011112222"),
        password_hash: none_str,
        auth_provider: "GOOGLE",
        status: "ACTIVE",
        kind: "USER",
        beneficial_owner_group: none_str,
        email_verified_at: some("2026-10-16T12:00:00Z"),
        verified_at: some("2026-10-16T12:00:00Z"),
        age_confirmed_at: some("2026-10-16T12:00:00Z"),
        created_at: "2026-10-16T12:00:00Z"
    };
    assert(is_eligible_for_grant(a));

    let unverified = Account {
        id: "acc_unverified",
        username: some("trader_two"),
        email: some("trader2@say.exchange"),
        phone_number: none_str,
        password_hash: none_str,
        auth_provider: "LOCAL",
        status: "ACTIVE",
        kind: "USER",
        beneficial_owner_group: none_str,
        email_verified_at: none_str,
        verified_at: none_str,
        age_confirmed_at: some("2026-10-16T12:00:00Z"),
        created_at: "2026-10-16T12:00:00Z"
    };
    assert(!is_eligible_for_grant(unverified));
}

fn has_err(x: opt[str]) -> bool {
    if let _e = x { return true; }
    return false;
}

fn test_validation_functions() {
    // Username tests
    assert(has_err(validate_username("ab")));
    assert(has_err(validate_username("bad-user")));
    assert(has_err(validate_username("toolongname")));
    assert(!has_err(validate_username("good_user1")));

    // Password tests
    assert(has_err(validate_password("short")));
    assert(has_err(validate_password("alllowercase1!")));
    assert(has_err(validate_password("ALLUPPERCASE1!")));
    assert(has_err(validate_password("NoDigitsHere!")));
    assert(has_err(validate_password("NoSpecial1234")));
    assert(!has_err(validate_password("ValidPass123!")));

    // Phone tests
    assert(has_err(validate_phone_number("09012345678")));
    assert(!has_err(validate_phone_number("+2349012345678")));
    assert(!has_err(validate_phone_number("")));

    // Email tests
    assert(has_err(validate_email("notanemail")));
    assert(has_err(validate_email("user@domain")));
    assert(!has_err(validate_email("user@domain.com")));
}

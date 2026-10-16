fn test_effective_owner_group_falls_back_to_id() {
    let none_str: opt[str] = none;
    let a1 = Account {
        id: "acc_1",
        email: some("test@example.com"),
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
        email: some("bot@example.com"),
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
        email: some("trader@say.exchange"),
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
        email: some("trader2@say.exchange"),
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

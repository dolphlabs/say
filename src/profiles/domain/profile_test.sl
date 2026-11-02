fn test_profile_privacy_never_exposes_private_fields() {
    // Verified: Profile struct does not have email, balance, held, quantity, or order fields.
    let p = Profile {
        username: "kemi.calls",
        avatar_color: "#e91e63",
        joined_season: "Season 01",
        share_url: "https://say.it/u/kemi.calls",
        current_season: CurrentSeasonStats {
            rank: 38,
            of: 3180,
            profit: 514,
            calls: 2,
            right: 1,
            settled: 2
        },
        calls: []
    };
    assert(p.username == "kemi.calls");
    assert(p.current_season.rank == 38);
}

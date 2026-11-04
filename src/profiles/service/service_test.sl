import "../domain" as domain;

gc struct FakeStoreContext {
    dummy: int
}

fn fake_find_user(ctx: FakeStoreContext, raw_username: str) -> result[AccountLookup, str] {
    if raw_username == "kemi.calls" {
        return ok(AccountLookup {
            found: true,
            redirect_username: "",
            account_id: "acc-1",
            username: "kemi.calls",
            avatar_color: "#e91e63",
            avatar_url: "",
            status: "ACTIVE",
            created_at_ms: 1000,
            joined_season: "Season 02"
        });
    }
    return ok(AccountLookup {
        found: false,
        redirect_username: "",
        account_id: "",
        username: "",
        avatar_color: "",
        avatar_url: "",
        status: "",
        created_at_ms: 0,
        joined_season: ""
    });
}

fn fake_load_profile_calls(ctx: FakeStoreContext, account_id: str) -> result[[domain.CallItem], str] {
    return ok([]);
}

fn fake_load_current_stats(ctx: FakeStoreContext, account_id: str) -> result[domain.CurrentSeasonStats, str] {
    return ok(domain.CurrentSeasonStats {
        rank: 38,
        of: 3180,
        profit: 514,
        calls: 2,
        right: 1,
        settled: 2
    });
}

fn test_profile_service_caching_and_lookup() {
    let ctx = FakeStoreContext { dummy: 0 };
    let st = ProfileStore[FakeStoreContext] {
        context: ctx,
        find_user: fake_find_user,
        load_profile_calls: fake_load_profile_calls,
        load_current_stats: fake_load_current_stats
    };
    let svc = new_service(st);

    let res = get_profile(svc, "kemi.calls", "https://say.it", 1000);
    guard let outcome = res else let e = err_of(res) { panic(e); }
    assert(outcome.status == "FOUND");
    guard let prof = outcome.profile else { panic("expected profile"); }
    assert(prof.username == "kemi.calls");
    assert(prof.current_season.rank == 38);
    assert(prof.joined_season == "Season 02", prof.joined_season);
    assert(prof.share_url == "https://say.it/u/kemi.calls", prof.share_url);

    // From cache
    let cached_res = get_profile(svc, "kemi.calls", "https://say.it", 2000);
    guard let c_out = cached_res else let e = err_of(cached_res) { panic(e); }
    assert(c_out.status == "FOUND");
}

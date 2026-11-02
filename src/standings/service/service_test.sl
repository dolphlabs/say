import "../domain" as domain;

gc struct FakeStoreContext {
    season: domain.SeasonInfo
}

fn fake_get_current_season(ctx: FakeStoreContext) -> result[opt[domain.SeasonInfo], str] {
    return ok(some(ctx.season));
}

fn fake_load_standings_rows(ctx: FakeStoreContext, ordinal: int, sort_by: str, limit_n: int) -> result[[domain.StandingsRow], str] {
    let r = domain.StandingsRow {
        account_id: "acc-1",
        username: "kemi.calls",
        avatar_color: "#e91e63",
        profit: 514,
        calls: 2,
        wins: 1,
        losses: 1,
        profit_reached_at: 1000,
        rank_profit: 1,
        rank_win: none,
        rank_calls: 1,
        win_rate: "",
        leaderboard_eligible: true
    };
    return ok([r]);
}

fn fake_recompute_season_standings(ctx: FakeStoreContext, now_ms: int) -> result[int, str] {
    return ok(1);
}

fn fake_freeze_final_standings(ctx: FakeStoreContext, season_id: str, now_ms: int) -> result[bool, str] {
    return ok(true);
}

fn test_standings_service_lifecycle() {
    let ctx = FakeStoreContext {
        season: domain.SeasonInfo {
            ordinal: 1,
            status: "ACTIVE",
            starts_at: 1000,
            ends_at: 2000,
            players: 1,
            provisional: false,
            provisional_reason: ""
        }
    };
    let st = StandingsStore[FakeStoreContext] {
        context: ctx,
        get_current_season: fake_get_current_season,
        load_standings_rows: fake_load_standings_rows,
        recompute_season_standings: fake_recompute_season_standings,
        freeze_final_standings: fake_freeze_final_standings
    };
    let svc = new_service(st);

    let refresh_r = refresh_snapshot(svc, 1500);
    guard let _ = refresh_r else let e = err_of(refresh_r) { panic("refresh failed: " + e); }

    let board_r = get_leaderboard(svc, "profit", 10, "", "acc-1");
    guard let board = board_r else let e = err_of(board_r) { panic(e); }
    assert(len(board.items) == 1);
    assert(board.items[0].username == "kemi.calls");

    let strip_r = get_strip(svc);
    guard let strip = strip_r else let e = err_of(strip_r) { panic(e); }
    assert(len(strip) == 1);
}

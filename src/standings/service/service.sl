import "time";
import "../domain" as domain;

pub gc struct StandingsService[C] {
    store: StandingsStore[C],
    snapshot: opt[domain.StandingsSnapshot],
    snapshot_lock: mutex
}

pub fn new_service[C](s: StandingsStore[C]) -> StandingsService[C] {
    let none_snap: opt[domain.StandingsSnapshot] = none;
    return StandingsService[C] {
        store: s,
        snapshot: none_snap,
        snapshot_lock: make_mutex()
    };
}

pub fn refresh_snapshot[C](svc: StandingsService[C], now_ms: int) -> result[bool, str] {
    // 1. Recompute standings in db
    let comp_fn = svc.store.recompute_season_standings;
    let comp_res = comp_fn(svc.store.context, now_ms);
    guard let _ok = comp_res else let e = err_of(comp_res) {
        return err("recompute failed: " + e);
    }

    // 2. Load season info
    let season_fn = svc.store.get_current_season;
    let season_res = season_fn(svc.store.context);
    guard let opt_season = season_res else let e = err_of(season_res) {
        return err("get season failed: " + e);
    }
    guard let season = opt_season else {
        return err("no active season found");
    }

    // 3. Load top 100 for each sort
    let load_fn = svc.store.load_standings_rows;
    let profit_res = load_fn(svc.store.context, season.ordinal, "profit", 100);
    guard let rows_profit = profit_res else let e = err_of(profit_res) {
        return err("load profit failed: " + e);
    }

    let win_res = load_fn(svc.store.context, season.ordinal, "win_rate", 100);
    guard let rows_win = win_res else let e = err_of(win_res) {
        return err("load win failed: " + e);
    }

    let calls_res = load_fn(svc.store.context, season.ordinal, "calls", 100);
    guard let rows_calls = calls_res else let e = err_of(calls_res) {
        return err("load calls failed: " + e);
    }

    let acc_map: map[str]domain.StandingsRow = {};
    for r in rows_profit {
        acc_map[r.account_id] = r;
    }

    let snap = domain.StandingsSnapshot {
        season: season,
        by_profit: rows_profit,
        by_win_rate: rows_win,
        by_calls: rows_calls,
        account_map: acc_map,
        computed_at: now_ms
    };

    mutex_lock(svc.snapshot_lock);
    svc.snapshot = some(snap);
    mutex_unlock(svc.snapshot_lock);

    return ok(true);
}

pub fn get_leaderboard[C](svc: StandingsService[C], sort_by: str, limit_n: int, cursor: str, caller_account_id: str) -> result[domain.LeaderboardPage, str] {
    mutex_lock(svc.snapshot_lock);
    let opt_snap = svc.snapshot;
    mutex_unlock(svc.snapshot_lock);

    guard let snap = opt_snap else {
        return err("STANDINGS_WARMING");
    }

    let selected_rows = snap.by_profit;
    if sort_by == "win_rate" {
        selected_rows = snap.by_win_rate;
    } else if sort_by == "calls" {
        selected_rows = snap.by_calls;
    }

    let podium: [domain.StandingsRow] = [];
    for i in 0..len(selected_rows) {
        if i < 3 {
            push(podium, selected_rows[i]);
        }
    }

    let items: [domain.StandingsRow] = [];
    let limit = limit_n;
    if limit <= 0 || limit > 100 { limit = 50; }
    for i in 0..len(selected_rows) {
        if i < limit {
            push(items, selected_rows[i]);
        }
    }

    let opt_me: opt[domain.PersonalStanding] = none;
    if caller_account_id != "" && has(snap.account_map, caller_account_id) {
        let me_row = snap.account_map[caller_account_id];
        let rank_20_profit = 0;
        if len(snap.by_profit) >= 20 {
            rank_20_profit = snap.by_profit[19].profit;
        }
        let to_top20 = domain.calculate_to_top20(me_row.profit, rank_20_profit, me_row.rank_profit);
        let pct = domain.calculate_percentile(me_row.rank_profit, snap.season.players);

        opt_me = some(domain.PersonalStanding {
            rank: me_row.rank_profit,
            of: snap.season.players,
            profit: me_row.profit,
            percentile_label: pct,
            to_top20: to_top20,
            row: me_row
        });
    }

    return ok(domain.LeaderboardPage {
        season: snap.season,
        podium: podium,
        items: items,
        next_cursor: "",
        me: opt_me
    });
}

pub fn get_strip[C](svc: StandingsService[C]) -> result[[domain.StandingsRow], str] {
    mutex_lock(svc.snapshot_lock);
    let opt_snap = svc.snapshot;
    mutex_unlock(svc.snapshot_lock);

    guard let snap = opt_snap else {
        return err("STANDINGS_WARMING");
    }

    let strip: [domain.StandingsRow] = [];
    for i in 0..len(snap.by_profit) {
        if i < 5 {
            push(strip, snap.by_profit[i]);
        }
    }
    return ok(strip);
}

pub fn run_standings_worker[C](svc: StandingsService[C]) -> int {
    while true {
        let now_ms = (time.mono() / 1000000) as int;
        let _ = refresh_snapshot(svc, now_ms);
        time.sleep(30000000000); // 30 seconds
    }
    return 0;
}

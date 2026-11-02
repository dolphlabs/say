import "timez";

pub gc struct StandingsRow {
    account_id: str,
    username: str,
    avatar_color: str,
    profit: int,
    calls: int,
    wins: int,
    losses: int,
    profit_reached_at: int,
    rank_profit: int,
    rank_win: opt[int],
    rank_calls: int,
    win_rate: str,
    leaderboard_eligible: bool
}

pub gc struct SeasonInfo {
    ordinal: int,
    status: str,
    starts_at: int,
    ends_at: int,
    players: int,
    provisional: bool,
    provisional_reason: str
}

pub gc struct PersonalStanding {
    rank: int,
    of: int,
    profit: int,
    percentile_label: str,
    to_top20: opt[int],
    row: StandingsRow
}

pub gc struct LeaderboardPage {
    season: SeasonInfo,
    podium: [StandingsRow],
    items: [StandingsRow],
    next_cursor: str,
    me: opt[PersonalStanding]
}

pub gc struct StandingsSnapshot {
    season: SeasonInfo,
    by_profit: [StandingsRow],
    by_win_rate: [StandingsRow],
    by_calls: [StandingsRow],
    account_map: map[str]StandingsRow,
    computed_at: int
}

pub fn calculate_win_rate(wins: int, losses: int) -> str {
    let total = wins + losses;
    if total < 5 {
        return "";
    }
    let pct = (wins * 100) / total;
    return to_str(pct) + "%";
}

pub fn calculate_percentile(rank: int, total_players: int) -> str {
    if total_players <= 0 || rank <= 0 {
        return "top 100%";
    }
    let pct = ((rank * 100) + total_players - 1) / total_players;
    if pct < 1 { pct = 1; }
    if pct > 100 { pct = 100; }
    return "top " + to_str(pct) + "%";
}

pub fn calculate_to_top20(my_profit: int, rank_20_profit: int, my_rank: int) -> opt[int] {
    if my_rank <= 20 {
        return none;
    }
    let diff = rank_20_profit - my_profit + 1;
    if diff <= 0 {
        return some(1);
    }
    return some(diff);
}

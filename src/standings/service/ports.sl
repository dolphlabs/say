import "../domain" as domain;

pub gc struct StandingsStore[C] {
    context: C,
    get_current_season: fn(C) -> result[opt[domain.SeasonInfo], str],
    load_standings_rows: fn(C, int, str, int) -> result[[domain.StandingsRow], str],
    recompute_season_standings: fn(C, int) -> result[int, str],
    freeze_final_standings: fn(C, str, int) -> result[bool, str]
}

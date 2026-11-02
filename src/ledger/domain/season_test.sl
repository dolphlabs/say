import "timez";

fn anchor() -> timez.Time {
    let r = timez.parse_rfc3339("2026-10-11T23:00:00Z");
    guard let t = r else { panic("anchor"); }
    return t;
}

fn at(s: str) -> timez.Time {
    let r = timez.parse_rfc3339(s);
    guard let t = r else let e = err_of(r) { panic(e); }
    return t;
}

fn lagos() -> timez.Zone {
    let r = timez.load_zone("Africa/Lagos");
    guard let z = r else let e = err_of(r) { panic(e); }
    return z;
}

fn season(ordinal: int, status: str) -> Season {
    return Season { id: "s" + to_str(ordinal), ordinal: ordinal, starts_at: starts_at(anchor(), ordinal),
                    ends_at: ends_at(anchor(), ordinal), status: status };
}

fn test_should_start_season_one_at_midnight_lagos_on_12_october() {
    assert(starts_at(anchor(), 1).rfc3339() == "2026-10-11T23:00:00Z");
    assert(starts_at(anchor(), 1).in_zone(lagos()).rfc3339() == "2026-10-12T00:00:00+01:00");
    assert(starts_at(anchor(), 1).in_zone(lagos()).weekday() == timez.Weekday.MONDAY);
}

fn test_should_place_season_n_at_anchor_plus_n_minus_one_fortnights() {
    assert(starts_at(anchor(), 2).rfc3339() == "2026-10-25T23:00:00Z");
    assert(ends_at(anchor(), 1).rfc3339() == "2026-10-25T23:00:00Z");
    assert(starts_at(anchor(), 27).rfc3339() == "2027-10-10T23:00:00Z");
    assert(starts_at(anchor(), 27).in_zone(lagos()).hour() == 0);
}

fn test_should_keep_the_last_millisecond_in_the_old_season() {
    assert(ordinal_at(anchor(), at("2026-10-25T22:59:59.999Z")) == 1);
    assert(ordinal_at(anchor(), at("2026-10-25T23:00:00.000Z")) == 2);
    assert(ordinal_at(anchor(), at("2026-10-11T22:59:59.999Z")) == 0);
    assert(ordinal_at(anchor(), anchor()) == 1);
}

fn test_should_treat_season_windows_as_half_open() {
    let s = season(1, active());
    assert(contains(s, s.starts_at));
    assert(!contains(s, s.ends_at));
    assert(contains(s, at("2026-10-25T22:59:59.999Z")));
}

fn test_should_count_days_in_lagos_calendar_days() {
    let s = season(1, active());
    assert(day_of(s, at("2026-10-11T23:00:00Z"), lagos()) == 1);
    assert(day_of(s, at("2026-10-12T22:59:59Z"), lagos()) == 1);
    assert(day_of(s, at("2026-10-12T23:00:00Z"), lagos()) == 2);
    assert(day_of(s, at("2026-10-18T12:00:00Z"), lagos()) == 7);
    assert(day_of(s, at("2026-10-25T22:59:59Z"), lagos()) == 14);
    assert(day_of(s, at("2027-01-01T00:00:00Z"), lagos()) == 14);
}

fn test_should_close_the_old_season_before_activating_the_next() {
    let steps = time_steps([season(1, active()), season(2, scheduled())], at("2026-10-25T23:00:00Z"));
    assert(len(steps) == 2, inspect(steps));
    assert(steps[0].ordinal == 1 && steps[0].to == closing());
    assert(steps[1].ordinal == 2 && steps[1].to == active());
}

fn test_should_do_nothing_before_a_boundary() {
    let steps = time_steps([season(1, active()), season(2, scheduled())], at("2026-10-25T22:59:59.999Z"));
    assert(len(steps) == 0);
}

fn test_should_walk_missed_seasons_through_active_and_closing_in_order() {
    let steps = time_steps([season(1, scheduled()), season(2, scheduled()), season(3, scheduled())],
                           at("2026-11-09T00:00:00Z"));
    assert(len(steps) == 5, inspect(steps));
    assert(steps[0].ordinal == 1 && steps[0].to == active());
    assert(steps[1].ordinal == 1 && steps[1].to == closing());
    assert(steps[2].ordinal == 2 && steps[2].to == active());
    assert(steps[3].ordinal == 2 && steps[3].to == closing());
    assert(steps[4].ordinal == 3 && steps[4].to == active());
}

fn test_should_report_boundaries_two_minutes_overdue() {
    let s = [season(1, active()), season(2, scheduled())];
    assert(len(late_boundaries(s, at("2026-10-25T23:01:59Z"), 2 * timez.MINUTE)) == 0);
    assert(len(late_boundaries(s, at("2026-10-25T23:02:01Z"), 2 * timez.MINUTE)) == 2);
}

fn test_should_sleep_until_the_next_boundary_or_the_cap() {
    let s = [season(1, active()), season(2, scheduled())];
    assert(sleep_for(s, at("2026-10-25T22:59:30Z"), 60 * timez.SECOND) == 30 * timez.SECOND);
    assert(sleep_for(s, at("2026-10-20T00:00:00Z"), 60 * timez.SECOND) == 60 * timez.SECOND);
    assert(sleep_for(s, at("2026-10-25T23:00:05Z"), 60 * timez.SECOND) == 0);
}

fn test_should_allow_each_kind_only_in_its_season_statuses() {
    assert(kind_allowed("ORDER_HOLD", active()));
    assert(!kind_allowed("ORDER_HOLD", closing()));
    assert(kind_allowed("ORDER_RELEASE", closing()));
    assert(!kind_allowed("SEASON_GRANT", scheduled()));
    assert(kind_allowed("PAYOUT", active()));
    assert(kind_allowed("PAYOUT", closed()));
    assert(!kind_allowed("PAYOUT", finalized()));
    assert(kind_allowed("VOID_REFUND", active()));
    assert(!kind_allowed("VOID_REFUND", finalized()));
    assert(kind_allowed("FEE_REFUND", closed()));
    assert(kind_allowed("VOID_COLLATERAL_RELEASE", active()));
    assert(!kind_allowed("ADJUSTMENT", finalized()));
    assert(needs_active("FILL") && !needs_active("ORDER_RELEASE"));
    assert(!needs_active("PAYOUT") && !needs_active("VOID_REFUND"));
}

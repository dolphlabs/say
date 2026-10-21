import "timez";

pub gc struct Season {
    id: str,
    ordinal: int,
    starts_at: timez.Time,
    ends_at: timez.Time,
    status: str
}

pub fn scheduled() -> str { return "SCHEDULED"; }
pub fn active() -> str { return "ACTIVE"; }
pub fn closing() -> str { return "CLOSING"; }
pub fn closed() -> str { return "CLOSED"; }
pub fn finalized() -> str { return "FINALIZED"; }

pub fn days_total() -> int {
    return 14;
}

pub fn season_length() -> int {
    return days_total() * timez.DAY;
}

// Season N spans [anchor + (N-1)·14d, anchor + N·14d). Boundaries are
// pinned to the anchor instant; the zone matters only for display.
pub fn starts_at(anchor: timez.Time, ordinal: int) -> timez.Time {
    return anchor.add((ordinal - 1) * season_length());
}

pub fn ends_at(anchor: timez.Time, ordinal: int) -> timez.Time {
    return starts_at(anchor, ordinal + 1);
}

// 0 before the anchor.
pub fn ordinal_at(anchor: timez.Time, t: timez.Time) -> int {
    if t.before(anchor) {
        return 0;
    }
    return t.sub(anchor) / season_length() + 1;
}

pub fn contains(s: Season, t: timez.Time) -> bool {
    return !t.before(s.starts_at) && t.before(s.ends_at);
}

fn lagos_day(t: timez.Time, z: timez.Zone) -> int {
    let d = t.in_zone(z).date();
    return timez.days_from_civil(d.year, d.month, d.day);
}

// "Day 7 of 14", counted in the season's own calendar days.
pub fn day_of(s: Season, now: timez.Time, z: timez.Zone) -> int {
    let d = lagos_day(now, z) - lagos_day(s.starts_at, z) + 1;
    if d < 1 {
        return 1;
    }
    if d > days_total() {
        return days_total();
    }
    return d;
}

pub gc struct Step {
    season_id: str,
    ordinal: int,
    from: str,
    to: str
}

// The clock-driven transitions due at `now`, oldest season first. Each
// season is activated before it is closed, and closed before the next one
// activates, so applying them in order never has two ACTIVE seasons.
pub fn time_steps(seasons: [Season], now: timez.Time) -> [Step] {
    let out: [Step] = [];
    for s in seasons {
        let status = s.status;
        if status == scheduled() && !now.before(s.starts_at) {
            push(out, Step { season_id: s.id, ordinal: s.ordinal, from: scheduled(), to: active() });
            status = active();
        }
        if status == active() && !now.before(s.ends_at) {
            push(out, Step { season_id: s.id, ordinal: s.ordinal, from: active(), to: closing() });
        }
    }
    return out;
}

// Boundaries more than `grace_ns` overdue without their transition.
pub fn late_boundaries(seasons: [Season], now: timez.Time, grace_ns: int) -> [str] {
    let out: [str] = [];
    let cutoff = now.add(0 - grace_ns);
    for s in seasons {
        if s.status == scheduled() && s.starts_at.before(cutoff) {
            push(out, "season " + to_str(s.ordinal) + " should be ACTIVE since " + s.starts_at.rfc3339());
        }
        if s.status == active() && s.ends_at.before(cutoff) {
            push(out, "season " + to_str(s.ordinal) + " should be CLOSING since " + s.ends_at.rfc3339());
        }
    }
    return out;
}

// How long the scheduler may sleep: until the next boundary, at most `cap_ns`.
pub fn sleep_for(seasons: [Season], now: timez.Time, cap_ns: int) -> int {
    let best = cap_ns;
    for s in seasons {
        let at = s.ends_at;
        if s.status == scheduled() {
            at = s.starts_at;
        } else if s.status != active() {
            continue;
        }
        let d = at.sub(now);
        if d < best {
            best = d;
        }
    }
    if best < 0 {
        return 0;
    }
    return best;
}

// Which postings a season accepts in each status.
pub fn kind_allowed(kind: str, status: str) -> bool {
    if kind == "ORDER_RELEASE" {
        return status == active() || status == closing();
    }
    if kind == "PAYOUT" {
        return status == closing() || status == closed();
    }
    if kind == "ADJUSTMENT" {
        return status != finalized();
    }
    return status == active();
}

// Kinds that need ACTIVE also share-lock the season row, so the
// ACTIVE -> CLOSING update waits for them and later ones see CLOSING.
pub fn needs_active(kind: str) -> bool {
    return kind != "ORDER_RELEASE" && kind != "PAYOUT" && kind != "ADJUSTMENT";
}

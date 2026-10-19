import "timez";
import "../domain" as domain;

pub gc struct Ledger[C] {
    seasons: SeasonStore[C]
}

pub fn new_ledger[C](seasons: SeasonStore[C]) -> Ledger[C] {
    return Ledger[C] { seasons: seasons };
}

pub fn current_season[C](l: Ledger[C]) -> result[opt[domain.Season], str] {
    let f = l.seasons.current;
    return f(l.seasons.context);
}

pub fn current_season_end[C](l: Ledger[C]) -> result[opt[timez.Time], str] {
    let r = current_season(l);
    guard let found = r else let e = err_of(r) {
        return err(e);
    }
    let none_end: opt[timez.Time] = none;
    guard let s = found else {
        return ok(none_end);
    }
    return ok(some(s.ends_at));
}

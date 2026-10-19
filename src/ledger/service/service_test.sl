import "timez";
import "../domain" as domain;

gc struct FakeSeasons {
    season: opt[domain.Season],
    fail: bool
}

fn fake_current(f: FakeSeasons) -> result[opt[domain.Season], str] {
    if f.fail {
        return err("down");
    }
    return ok(f.season);
}

fn with(f: FakeSeasons) -> Ledger[FakeSeasons] {
    return new_ledger(SeasonStore[FakeSeasons] { context: f, current: fake_current });
}

fn test_should_return_the_active_season() {
    let s = domain.Season { id: "s1", ordinal: 1, starts_at: timez.unix(0), ends_at: timez.unix(1209600), status: "ACTIVE" };
    let r = current_season(with(FakeSeasons { season: some(s), fail: false }));
    guard let found = r else { panic("err"); }
    guard let season = found else { panic("none"); }
    assert(season.ordinal == 1);
}

fn test_should_pass_store_failures_through() {
    let none_season: opt[domain.Season] = none;
    let r = current_season(with(FakeSeasons { season: none_season, fail: true }));
    if let _v = r {
        panic("expected err");
    }
}

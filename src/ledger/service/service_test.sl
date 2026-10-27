import "timez";
import "../domain" as domain;

gc struct Fake {
    lock: mutex,
    lease_free: bool,
    ticks: int,
    seasons: [domain.Season],
    accounts: [str],
    chunks: [[str]],
    granted: int,
    cap: int,
    finished_halt: str,
    finished: bool,
    cursor: str
}

fn new_fake() -> Fake {
    let s: [domain.Season] = [];
    let a: [str] = [];
    let c: [[str]] = [];
    return Fake { lock: make_mutex(), lease_free: true, ticks: 0, seasons: s, accounts: a, chunks: c, granted: 0,
                  cap: 1000000, finished_halt: "", finished: false, cursor: "" };
}

fn anchor() -> timez.Time {
    return timez.unix(1760223600);
}

fn season_one() -> domain.Season {
    return domain.Season { id: "s1", ordinal: 1, starts_at: domain.starts_at(anchor(), 1), ends_at: domain.ends_at(anchor(), 1),
                           status: "ACTIVE" };
}

fn f_current(f: Fake) -> result[opt[domain.Season], str] {
    return ok(some(season_one()));
}

fn f_by_ordinal(f: Fake, n: int) -> result[opt[domain.Season], str] {
    let none_s: opt[domain.Season] = none;
    if n == 1 {
        return ok(some(season_one()));
    }
    return ok(none_s);
}

fn f_open(f: Fake) -> result[[domain.Season], str] {
    return ok(f.seasons);
}

fn f_lease_try(f: Fake, key: int) -> result[opt[int], str] {
    let none_id: opt[int] = none;
    mutex_lock(f.lock);
    let free = f.lease_free;
    f.lease_free = false;
    mutex_unlock(f.lock);
    if !free {
        return ok(none_id);
    }
    return ok(some(key));
}

fn f_lease_release(f: Fake, id: int) {
    mutex_lock(f.lock);
    f.lease_free = true;
    mutex_unlock(f.lock);
}

fn f_tick(f: Fake, now: timez.Time, a: timez.Time) -> result[TickReport, str] {
    f.ticks += 1;
    let steps: [domain.Step] = [];
    let closed: [int] = [];
    let problems: [str] = [];
    return ok(TickReport { steps: steps, closed: closed, rollover: "", problems: problems });
}

fn f_grant_run(f: Fake, season: str) -> result[GrantRun, str] {
    return ok(GrantRun { season_id: season, last_account_id: f.cursor, granted: 0, skipped: 0, finished: f.finished,
                         halted_reason: "" });
}

fn f_eligible_after(f: Fake, cursor: str, limit: int) -> result[[str], str] {
    let out: [str] = [];
    for a in f.accounts {
        if a > cursor && len(out) < limit {
            push(out, a);
        }
    }
    return ok(out);
}

fn f_grant_chunk(f: Fake, season: str, ids: [str]) -> result[ChunkResult, str] {
    mutex_lock(f.lock);
    push(f.chunks, ids);
    let room = f.cap - f.granted;
    let n = len(ids);
    if n > room {
        n = room;
    }
    f.granted += n;
    mutex_unlock(f.lock);
    let halt = "";
    if n < len(ids) {
        halt = "issuance cap reached";
    }
    return ok(ChunkResult { granted: n, skipped: len(ids) - n, halt: halt });
}

fn f_grant_advance(f: Fake, season: str, cursor: str) -> result[bool, str] {
    mutex_lock(f.lock);
    f.cursor = cursor;
    mutex_unlock(f.lock);
    return ok(true);
}

fn f_grant_finish(f: Fake, season: str, halt: str) -> result[GrantRun, str] {
    f.finished = true;
    f.finished_halt = halt;
    return ok(GrantRun { season_id: season, last_account_id: f.cursor, granted: f.granted, skipped: 0, finished: true,
                         halted_reason: halt });
}

fn f_balance(f: Fake, account: str, ordinal: int) -> result[opt[Balance], str] {
    return ok(some(Balance { season_ordinal: 1, season_status: "ACTIVE", available: 1000, held: 0, starting_grant: some(1000) }));
}

fn f_page(f: Fake, account: str, ordinal: int, cursor: str, limit: int) -> result[opt[LedgerPage], str] {
    if cursor == "junk" {
        return err("bad cursor");
    }
    let items: [LedgerItem] = [];
    return ok(some(LedgerPage { season_ordinal: 1, items: items, next_cursor: "" }));
}

fn f_recon_request(f: Fake, actor: str) -> result[str, str] { return ok("run-1"); }
fn f_recon_run(f: Fake, full: bool) -> result[opt[ReconRun], str] {
    let none_run: opt[ReconRun] = none;
    return ok(none_run);
}
fn f_recon_latest(f: Fake) -> result[opt[ReconRun], str] {
    let none_run: opt[ReconRun] = none;
    return ok(none_run);
}
fn f_last_full(f: Fake) -> result[opt[timez.Time], str] {
    let none_t: opt[timez.Time] = none;
    return ok(none_t);
}
fn f_aggregate(f: Fake) -> result[int, str] { return ok(0); }
fn f_halt_state(f: Fake) -> result[Halt, str] {
    return ok(Halt { halted: false, reason: "", changed_at: timez.unix(0) });
}
fn f_halt_clear(f: Fake, actor: str, reason: str) -> result[bool, str] { return ok(true); }
fn f_propose(f: Fake, amount: int, cap: int, op: str) -> result[str, str] { return ok("p1"); }
fn f_approve(f: Fake, id: str, op: str) -> result[PolicyView, str] { return err("not in this fake"); }
fn f_policies(f: Fake) -> result[[PolicyView], str] {
    let none_v: [PolicyView] = [];
    return ok(none_v);
}

fn store_of(f: Fake) -> LedgerStore[Fake] {
    return LedgerStore[Fake] {
        context: f, current: f_current, by_ordinal: f_by_ordinal, open_seasons: f_open, lease_try: f_lease_try,
        lease_release: f_lease_release, tick: f_tick, grant_run: f_grant_run, eligible_after: f_eligible_after,
        grant_chunk: f_grant_chunk, grant_advance: f_grant_advance, grant_finish: f_grant_finish, balance: f_balance,
        ledger_page: f_page, recon_request: f_recon_request, recon_run: f_recon_run, recon_latest: f_recon_latest,
        last_full_recon: f_last_full, aggregate: f_aggregate, halt_state: f_halt_state, halt_clear: f_halt_clear,
        policy_propose: f_propose, policy_approve: f_approve, policies: f_policies
    };
}

fn ledger(f: Fake) -> Ledger[Fake] {
    let cfg = default_config(anchor(), timez.utc_zone());
    cfg.chunk_size = 10;
    cfg.grant_workers = 3;
    return new_ledger(store_of(f), cfg, timez.fixed_clock(timez.unix(1760500000)));
}

fn test_should_read_the_season_selector() {
    assert((season_selector("current") ?? -1) == 0);
    assert((season_selector("") ?? -1) == 0);
    assert((season_selector("3") ?? -1) == 3);
    if let _n = season_selector("0") {
        panic("0 accepted");
    }
}

fn test_should_skip_the_tick_but_still_watch_boundaries_without_the_lease() {
    let f = new_fake();
    f.lease_free = false;
    let late = season_one();
    f.seasons = [late];
    let l = ledger(f);
    let _w = season_tick(l, late.ends_at.add(3 * timez.MINUTE));
    assert(f.ticks == 0);
    let found = false;
    while true {
        let got = false;
        select {
            case let s = chan_recv(l.signals) {
                if let sig = s {
                    got = true;
                    found = found || sig.name == "season.transition_late";
                }
            }
            default {}
        }
        if !got {
            break;
        }
    }
    assert(found);
}

fn ids(n: int) -> [str] {
    let out: [str] = [];
    for i in 0..n {
        let s = to_str(1000 + i);
        push(out, "acct-" + s);
    }
    return out;
}

fn test_should_grant_in_bounded_chunks_and_finish() {
    let f = new_fake();
    f.accounts = ids(95);
    let l = ledger(f);
    let n = run_rollover(l, "s1");
    assert(n == 95, to_str(n));
    assert(len(f.chunks) == 10, to_str(len(f.chunks)));
    for c in f.chunks {
        assert(len(c) <= 10);
    }
    assert(f.finished && len(f.finished_halt) == 0);
    assert(f.cursor == "acct-1094", f.cursor);
    assert(f.lease_free, "lease not released");
}

fn test_should_stop_at_the_cap_and_finish_with_the_reason() {
    let f = new_fake();
    f.accounts = ids(95);
    f.cap = 25;
    let l = ledger(f);
    let n = run_rollover(l, "s1");
    assert(n == 25, to_str(n));
    assert(f.finished_halt == "issuance cap reached");
    assert(len(f.chunks) < 10, "kept granting past the cap");
}

fn test_should_resume_from_the_saved_cursor() {
    let f = new_fake();
    f.accounts = ids(30);
    f.cursor = "acct-1019";
    let n = run_rollover(ledger(f), "s1");
    assert(n == 10, to_str(n));
}

fn test_should_not_run_a_finished_rollover_or_one_another_instance_holds() {
    let f = new_fake();
    f.accounts = ids(30);
    f.finished = true;
    assert(run_rollover(ledger(f), "s1") == 0);
    let g = new_fake();
    g.accounts = ids(30);
    g.lease_free = false;
    assert(run_rollover(ledger(g), "s1") == 0);
    assert(len(g.chunks) == 0);
}

fn test_should_fetch_the_summary_halves_together() {
    let r = summary(ledger(new_fake()), "acct-1");
    guard let s = r else let e = err_of(r) { panic(e.detail); }
    guard let v = s.season else { panic("no season"); }
    guard let b = s.balance else { panic("no balance"); }
    assert(v.season.ordinal == 1 && b.available == 1000);
}

fn test_should_validate_requests_before_the_store() {
    let l = ledger(new_fake());
    let page = ledger_page(l, "a", 0, "", 0);
    guard let _p = page else let e = err_of(page) {
        assert(e.why == Why.BadRequest);
        let bad = ledger_page(l, "a", 0, "junk", 10);
        guard let _q = bad else let e2 = err_of(bad) {
            assert(e2.why == Why.BadRequest);
            if let _c = clear_halt(l, "op", "x") {
                panic("empty reason accepted");
            }
            if let _p2 = propose_policy(l, 1000, 999, "op") {
                panic("cap below amount accepted");
            }
            return;
        }
        panic("junk cursor accepted");
    }
    panic("limit 0 accepted");
}

fn test_should_show_day_and_provisional_reason() {
    let r = season(ledger(new_fake()), 1);
    guard let v = r else let e = err_of(r) { panic(e.detail); }
    assert(v.day >= 1 && v.day <= 14);
    assert(!v.finalized && len(v.provisional_reason) > 0);
    let missing = season(ledger(new_fake()), 2);
    guard let _m = missing else let e = err_of(missing) {
        assert(e.why == Why.NotFound);
        return;
    }
    panic("season 2 found");
}

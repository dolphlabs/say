import "pg";
import "strings";
import "timez";
import "zokor";
import "../domain" as domain;
import "../service" as service;

fn ledger_on(e: Env, now: str) -> service.Ledger[Postgres] {
    let z = timez.load_zone("Africa/Lagos");
    guard let zone = z else let x = err_of(z) { panic(x); }
    let cfg = service.default_config(anchor(), zone);
    cfg.chunk_size = 50;
    return service.new_ledger(ledger_store(e.store), cfg, timez.fixed_clock(at(now)));
}

fn add_users(e: Env, n: int) {
    run_args(e.owner,
        "insert into accounts (username, email, status, email_verified_at) " +
        "select 'bulk' || g || '_' || substr(md5(random()::text), 1, 6), 'bulk' || g || '_' || substr(md5(random()::text), 1, 6) || '@test.say', " +
        "'ACTIVE', now() from generate_series(1, $1) g", [pg.arg_int(n)]);
}

fn eligible_count(e: Env) -> int {
    return int_of(e.app, "select count(*)::bigint as n from accounts where kind = 'USER' and status = 'ACTIVE' " +
                         "and email_verified_at is not null and deleted_at is null", no_args());
}

gc struct CrashArg {
    season: str,
    ids: [str]
}

// Posts a chunk's grants, then fails before COMMIT: what a crash mid-chunk
// leaves behind, which must be nothing.
fn crash_body(c: pg.Conn, a: CrashArg) -> result[int, str] {
    let r = grant_accounts(c, a.season, a.ids, dl());
    guard let _b = r else let x = err_of(r) { return err(domain.encode(x)); }
    return err("killed mid-chunk");
}

fn test_should_resume_a_killed_rollover_without_doubles_or_gaps() {
    guard let e = ready() else { return; }
    let s1 = season_id(e, 1);
    add_users(e, 230);
    let total = eligible_count(e);
    let _run = st_grant_run(e.store, s1);
    let first = st_eligible_after(e.store, "", 50);
    guard let ids = first else let x = err_of(first) { panic(x); }
    let ok1 = st_grant_chunk(e.store, s1, ids);
    guard let _c = ok1 else let x = err_of(ok1) { panic(x); }
    let _adv = st_grant_advance(e.store, s1, ids[len(ids) - 1]);
    let second = st_eligible_after(e.store, ids[len(ids) - 1], 50);
    guard let ids2 = second else let x = err_of(second) { panic(x); }
    let crashed = zokor.transaction(e.app, CrashArg { season: s1, ids: ids2 }, crash_body, dl());
    if let _n = crashed {
        panic("crash body committed");
    }
    assert(int_of(e.app, "select count(*)::bigint as n from issuance_grants", no_args()) == 50);

    let l = ledger_on(e, "2026-10-12T10:05:00Z");
    let granted = service.run_rollover(l, s1);
    assert(granted == total - 50, to_str(granted) + " of " + to_str(total - 50));
    assert(int_of(e.app, "select count(*)::bigint as n from issuance_grants", no_args()) == total);
    assert(int_of(e.app, "select count(distinct account_id)::bigint as n from issuance_grants", no_args()) == total);
    assert(int_of(e.app, "select count(*)::bigint as n from accounts a where a.kind = 'USER' and a.status = 'ACTIVE' " +
                         "and not exists (select 1 from issuance_grants g where g.account_id = a.id)", no_args()) == 0);
    assert(text_of(e.app, "select (finished_at is not null)::text as t from grant_runs where season_id = $1::uuid",
                   [pg.arg_text(s1)]) == "true");
    assert(int_of(e.app, "select count(*)::bigint as n from outbox_events where type = 'season.grants_done'", no_args()) == 1);
    assert(service.run_rollover(l, s1) == 0);
    assert_books_balance(e, "after rollover");
    drop_env(e);
}

fn tick_on(l: service.Ledger[Postgres], now: str) -> int {
    return service.season_tick(l, at(now));
}

fn test_should_apply_each_transition_once_with_two_instances() {
    guard let e = fresh_env() else { return; }
    let other = Env { name: e.name, base: e.base, owner: e.owner, app: open_pool(e.app_url, 8),
                      store: new_postgres(open_pool(e.app_url, 8), e.store.redis, 10000000000, 50000000), app_url: e.app_url };
    let a = ledger_on(e, "2026-10-12T10:00:00Z");
    let b = ledger_on(other, "2026-10-12T10:00:00Z");
    for now in ["2026-10-12T10:00:00Z", "2026-10-25T23:00:00Z", "2026-11-08T23:00:00Z"] {
        let ha = spawn tick_on(a, now);
        let hb = spawn tick_on(b, now);
        let _x = join_wait(ha);
        let _y = join_wait(hb);
    }
    assert(int_of(e.app, "select count(*)::bigint as n from outbox_events where type = 'season.started'", no_args()) == 3);
    assert(int_of(e.app, "select count(*)::bigint as n from outbox_events where type = 'season.closing'", no_args()) == 2);
    assert(status_of(e, 3) == "ACTIVE" && status_of(e, 2) == "CLOSED");
    let late = int_of(e.app, "select count(*)::bigint as n from seasons where status = 'ACTIVE'", no_args());
    assert(late == 1);
    drop_env(e);
}

fn test_should_signal_a_boundary_left_unapplied_for_two_minutes() {
    guard let e = fresh_env() else { return; }
    let l = ledger_on(e, "2026-10-12T10:00:00Z");
    let _w = service.season_tick(l, at("2026-10-12T10:00:00Z"));
    let hold = st_lease_try(e.store, service.lock_seasons());
    guard let held = hold else let x = err_of(hold) { panic(x); }
    guard let id = held else { panic("lease"); }
    let other = ledger_on(e, "2026-10-25T23:03:00Z");
    let _v = service.season_tick(other, at("2026-10-25T23:03:00Z"));
    st_lease_release(e.store, id);
    let found = false;
    while true {
        let got = false;
        select {
            case let s = chan_recv(other.signals) {
                if let sig = s {
                    got = true;
                    if sig.level == "critical" && sig.name == "season.transition_late" {
                        found = true;
                    }
                }
            }
            default {}
        }
        if !got {
            break;
        }
    }
    assert(found, "no late-boundary alert");
    drop_env(e);
}

gc struct Timing {
    ms: int,
    errors: int,
    first: str
}

gc struct LaneResult {
    errors: int,
    first: str
}

fn grant_lane(e: Env, season: str, ids: [str], lock_issuance: bool) -> LaneResult {
    let out = LaneResult { errors: 0, first: "" };
    for id in ids {
        let r = zokor.transaction(e.app, GrantArg { account: id, season: season, lock_issuance: lock_issuance }, grant_body, dl());
        let problem = "";
        if let n = r {
            if n != 1000 {
                problem = "granted " + to_str(n);
            }
        } else let x = err_of(r) {
            problem = x;
        }
        if len(problem) > 0 {
            out.errors += 1;
            if len(out.first) == 0 {
                out.first = problem;
            }
        }
    }
    return out;
}

fn grant_all(e: Env, season: str, ids: [str], lanes: int, lock_issuance: bool) -> Timing {
    let parts: [[str]] = [];
    for i in 0..lanes {
        let p: [str] = [];
        push(parts, p);
    }
    for i in 0..len(ids) {
        push(parts[i % lanes], ids[i]);
    }
    let sw = timez.start_stopwatch();
    let hs: [join[LaneResult]] = [];
    for p in parts {
        push(hs, spawn grant_lane(e, season, p, lock_issuance));
    }
    let errors = 0;
    let first = "";
    for h in hs {
        let r = join_wait(h);
        guard let lr = r else let x = err_of(r) {
            errors += 1;
            first = x;
            continue;
        }
        errors += lr.errors;
        if len(first) == 0 {
            first = lr.first;
        }
    }
    return Timing { ms: sw.elapsed() / timez.MILLISECOND, errors: errors, first: first };
}

fn bulk_ids(e: Env, n: int, tag: str) -> [str] {
    run_args(e.owner,
        "insert into accounts (username, email, status, email_verified_at) " +
        "select $2 || g, $2 || g || '@test.say', 'ACTIVE', now() from generate_series(1, $1) g",
        [pg.arg_int(n), pg.arg_text(tag)]);
    let pattern = tag + "%";
    let r: result[[IdRow], str] = zokor.query_all(e.app,
        "select id::text as id from accounts where username like $1 order by id", [pg.arg_text(pattern)], dl());
    guard let rows = r else let x = err_of(r) { panic(x); }
    let out: [str] = [];
    for row in rows {
        push(out, row.id);
    }
    return out;
}

// Test 4: 5,000 grants to different accounts, 32 at a time. The insert-only
// issuance wallet is compared with a variant that locks it first, which is
// what a cached system balance would cost.
fn test_should_not_serialise_grants_on_the_issuance_account() {
    guard let e = ready() else { return; }
    let s1 = season_id(e, 1);
    let free_ids = bulk_ids(e, 5000, "hotfree");
    let locked_ids = bulk_ids(e, 5000, "hotlock");
    let insert_only = grant_all(e, s1, free_ids, 32, false);
    let locking = grant_all(e, s1, locked_ids, 32, true);
    assert(insert_only.errors == 0 && locking.errors == 0, inspect(insert_only) + " " + inspect(locking));
    println("hot account: 5000 grants, 32 concurrent: insert-only " + to_str(insert_only.ms) + " ms (" +
            to_str(5000000 / (insert_only.ms + 1)) + "/s); locking " + to_str(locking.ms) + " ms (" +
            to_str(5000000 / (locking.ms + 1)) + "/s)");
    assert(int_of(e.app, "select count(*)::bigint as n from issuance_grants", no_args()) == 10000);
    assert_books_balance(e, "after 10,000 grants");
    drop_env(e);
}

// ---- property: random sequences keep every check green, and replay ----

gc struct Model {
    users: [str],
    holds: [str],
    hold_left: [int]
}

fn step(e: Env, season: str, m: Model, seed: int, i: int) -> str {
    let op = pick(seed, i, 0, 5);
    let a = pick(seed, i, 2, len(m.users));
    let b = pick(seed, i, 4, len(m.users) - 1);
    if b >= a {
        b += 1;
    }
    let amount = 1 + pick(seed, i, 6, 60);
    let key = "p:" + to_str(i);
    if op == 0 {
        let _g = grant(e, m.users[a], season);
        return "grant";
    }
    if op == 1 {
        let r = zokor.transaction(e.app, HoldArg { owner: m.users[a], season: season, amount: amount, key: key }, hold_body, dl());
        if let h = r {
            push(m.holds, h);
            push(m.hold_left, amount);
            return "hold";
        }
        return "hold refused";
    }
    if op == 2 && len(m.holds) > 0 {
        let k = pick(seed, i, 8, len(m.holds));
        let n = 1 + pick(seed, i, 10, m.hold_left[k] + 2);
        let r = zokor.transaction(e.app, ReleaseArg { hold: m.holds[k], amount: n, key: key }, release_body, dl());
        if let _t = r {
            m.hold_left[k] = m.hold_left[k] - n;
            return "release";
        }
        return "release refused";
    }
    if op == 3 && len(m.holds) > 0 {
        let k = pick(seed, i, 8, len(m.holds));
        let n = 2 + pick(seed, i, 10, m.hold_left[k] + 2);
        let r = zokor.transaction(e.app, ConsumeArg { hold: m.holds[k], amount: n, to: m.users[b], key: key }, consume_body, dl());
        if let _t = r {
            m.hold_left[k] = m.hold_left[k] - n;
            return "consume";
        }
        return "consume refused";
    }
    let r = post_tx(e, adjust(season, key, domain.user(m.users[a]), domain.user(m.users[b]), amount));
    if let _p = r {
        return "transfer";
    }
    return "transfer refused";
}

gc struct Outcome {
    balances: [str],
    trace: [str]
}

fn play(seed: int, steps: int) -> opt[Outcome] {
    guard let e = ready() else {
        let none_o: opt[Outcome] = none;
        return none_o;
    }
    let s1 = season_id(e, 1);
    let users: [str] = [];
    for i in 0..50 {
        push(users, new_user(e));
    }
    let none_holds: [str] = [];
    let none_left: [int] = [];
    let m = Model { users: users, holds: none_holds, hold_left: none_left };
    let trace: [str] = [];
    for i in 0..steps {
        push(trace, step(e, s1, m, seed, i));
        assert_books_balance(e, "step " + to_str(i) + " (" + trace[i] + ")");
    }
    assert_books_balance(e, "end of sequence");
    let balances: [str] = [];
    for u in users {
        let w = wallet(e, s1, u);
        push(balances, to_str(w.free_units) + "/" + to_str(w.held_units));
    }
    drop_env(e);
    return some(Outcome { balances: balances, trace: trace });
}

fn test_should_keep_the_books_balanced_through_random_sequences_and_replay_them_exactly() {
    guard let first = play(7, 300) else { return; }
    guard let second = play(7, 300) else { return; }
    assert(inspect(first.trace) == inspect(second.trace));
    assert(inspect(first.balances) == inspect(second.balances), "replay diverged");
    let kinds = strings.join(first.trace, ",");
    for k in ["grant", "hold", "release", "consume", "transfer", "refused"] {
        assert(strings.contains(kinds, k), "sequence never exercised " + k);
    }
}

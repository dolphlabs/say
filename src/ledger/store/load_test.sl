import "pg";
import "proc";
import "timez";
import "zokor";
import "../domain" as domain;
import "../service" as service;

// The load numbers in docs/ledger/PERFORMANCE.md. Off unless LEDGER_LOAD=1:
// they insert 100k accounts and take minutes.
fn load_on() -> bool {
    if (proc.getenv("LEDGER_LOAD") ?? "") != "1" {
        println("skip ledger load tests (LEDGER_LOAD is not 1)");
        return false;
    }
    return true;
}

fn merge_sorted(xs: [int]) -> [int] {
    if len(xs) <= 1 {
        return xs;
    }
    let mid = len(xs) / 2;
    let a: [int] = [];
    let b: [int] = [];
    for i in 0..len(xs) {
        if i < mid {
            push(a, xs[i]);
        } else {
            push(b, xs[i]);
        }
    }
    let sa = merge_sorted(a);
    let sb = merge_sorted(b);
    let out: [int] = [];
    let i = 0;
    let j = 0;
    while i < len(sa) || j < len(sb) {
        if j >= len(sb) || (i < len(sa) && sa[i] <= sb[j]) {
            push(out, sa[i]);
            i += 1;
        } else {
            push(out, sb[j]);
            j += 1;
        }
    }
    return out;
}

fn pct(sorted: [int], p: int) -> str {
    let i = len(sorted) * p / 100;
    if i >= len(sorted) {
        i = len(sorted) - 1;
    }
    let us = sorted[i] / 1000;
    return to_str(us / 1000) + "." + to_str((us % 1000) / 100) + " ms";
}

fn report(label: str, samples: [int], wall_ms: int) {
    let s = merge_sorted(samples);
    println(label + ": n=" + to_str(len(s)) + " p50 " + pct(s, 50) + " p95 " + pct(s, 95) + " p99 " + pct(s, 99) +
            " max " + pct(s, 100) + " wall " + to_str(wall_ms) + " ms (" + to_str(len(s) * 1000 / (wall_ms + 1)) + "/s)");
}

fn test_load_rollover_grants_100k_accounts() {
    if !load_on() { return; }
    guard let e = fresh_env() else { return; }
    run_args(e.owner,
        "insert into accounts (username, email, status, email_verified_at) " +
        "select 'r' || g, 'r' || g || '@test.say', 'ACTIVE', now() from generate_series(1, $1) g", [pg.arg_int(100000)]);
    let _p = approve(e, 1000, 1000000000000);
    let l = ledger_on(e, "2026-10-12T10:00:00Z");
    l.cfg.chunk_size = 500;
    let rep = tick(e, "2026-10-12T10:00:00Z");
    let sw = timez.start_stopwatch();
    let granted = service.run_rollover(l, rep.rollover);
    let ms = sw.elapsed() / timez.MILLISECOND;
    println("rollover: " + to_str(granted) + " grants in " + to_str(ms) + " ms (" + to_str(granted * 1000 / (ms + 1)) +
            "/s), 4 workers, chunks of 500");
    assert(granted >= 100000, to_str(granted));
    assert_books_balance(e, "after 100k rollover");
    drop_env(e);
}

fn post_lane(e: Env, season: str, users: [str], lane: int, n: int) -> [int] {
    let out: [int] = [];
    for k in 0..n {
        let i = lane * 100000 + k;
        let sw = timez.start_stopwatch();
        let _r = transfer(e, season, users, i, 99);
        push(out, sw.elapsed());
    }
    return out;
}

fn test_load_post_under_contention() {
    if !load_on() { return; }
    guard let e = ready() else { return; }
    let s1 = season_id(e, 1);
    let users: [str] = [];
    for i in 0..20 {
        let u = new_user(e);
        fund(e, s1, u, 1000000);
        push(users, u);
    }
    let sw = timez.start_stopwatch();
    let hs: [join[[int]]] = [];
    for lane in 0..32 {
        push(hs, spawn post_lane(e, s1, users, lane, 200));
    }
    let all: [int] = [];
    for h in hs {
        let r = join_wait(h);
        guard let xs = r else let x = err_of(r) { panic(x); }
        for x in xs {
            push(all, x);
        }
    }
    report("post (transfer, 32 concurrent over 20 wallets)", all, sw.elapsed() / timez.MILLISECOND);
    assert_books_balance(e, "after contention");
    drop_env(e);
}

fn balance_lane(e: Env, users: [str], lane: int, n: int) -> [int] {
    let out: [int] = [];
    for k in 0..n {
        let sw = timez.start_stopwatch();
        let r = st_balance(e.store, users[(lane + k) % len(users)], 0);
        guard let _b = r else let x = err_of(r) { panic(x); }
        push(out, sw.elapsed());
    }
    return out;
}

fn test_load_balance_reads() {
    if !load_on() { return; }
    guard let e = ready() else { return; }
    let s1 = season_id(e, 1);
    let users: [str] = [];
    for i in 0..100 {
        let u = new_user(e);
        let _g = grant(e, u, s1);
        push(users, u);
    }
    for lanes in [1, 32] {
        let sw = timez.start_stopwatch();
        let hs: [join[[int]]] = [];
        for lane in 0..lanes {
            push(hs, spawn balance_lane(e, users, lane, 6400 / lanes));
        }
        let all: [int] = [];
        for h in hs {
            let r = join_wait(h);
            guard let xs = r else let x = err_of(r) { panic(x); }
            for x in xs {
                push(all, x);
            }
        }
        report("balance read, " + to_str(lanes) + " concurrent", all, sw.elapsed() / timez.MILLISECOND);
    }
    drop_env(e);
}

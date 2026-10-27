import "time";
import "timez";
import "../domain" as domain;

pub fn lock_seasons() -> int { return 7310001; }
pub fn lock_grants() -> int { return 7310002; }
pub fn lock_recon() -> int { return 7310003; }
pub fn lock_aggregate() -> int { return 7310004; }

fn lease[C](l: Ledger[C], key: int) -> opt[int] {
    let f = l.store.lease_try;
    let r = f(l.store.context, key);
    guard let got = r else let e = err_of(r) {
        signal(l, "warn", "ledger.lease_failed", 0, "advisory lock " + to_str(key) + ": " + e);
        return none;
    }
    return got;
}

fn unlease[C](l: Ledger[C], id: int) {
    let f = l.store.lease_release;
    f(l.store.context, id);
}

// One scheduler pass at `now`: whichever instance gets the lock applies
// every overdue transition; every instance checks for late boundaries.
// Returns how long to sleep.
pub fn season_tick[C](l: Ledger[C], now: timez.Time) -> int {
    if let id = lease(l, lock_seasons()) {
        let tick = l.store.tick;
        let r = tick(l.store.context, now, l.cfg.anchor);
        unlease(l, id);
        if let report = r {
            for s in report.steps {
                signal(l, "info", "season.transition", 0,
                       "season " + to_str(s.ordinal) + " " + s.from + " -> " + s.to);
                signal(l, "metric", "season_transitions_total{to=\"" + s.to + "\"}", 1, "");
            }
            for o in report.closed {
                signal(l, "info", "season.transition", 0, "season " + to_str(o) + " CLOSING -> CLOSED");
                signal(l, "metric", "season_transitions_total{to=\"CLOSED\"}", 1, "");
            }
            if len(report.steps) > 0 || len(report.closed) > 0 {
                kick_outbox(l);
            }
            if len(report.rollover) > 0 {
                spawn run_rollover(l, report.rollover);
            }
        } else let e = err_of(r) {
            signal(l, "critical", "season.tick_failed", 0, "season tick failed: " + e);
        }
    }
    let open = l.store.open_seasons;
    let sr = open(l.store.context);
    guard let seasons = sr else let e = err_of(sr) {
        signal(l, "warn", "season.read_failed", 0, e);
        return l.cfg.tick_cap_ns;
    }
    let late = domain.late_boundaries(seasons, now, l.cfg.late_grace_ns);
    for msg in late {
        signal(l, "critical", "season.transition_late", 0, msg);
    }
    signal(l, "metric", "season_transition_late", len(late), "gauge");
    return domain.sleep_for(seasons, now, l.cfg.tick_cap_ns);
}

pub fn run_season_scheduler[C](l: Ledger[C]) -> int {
    while true {
        let wait = season_tick(l, l.clock.now());
        // A boundary is applied a moment after it passes, never before.
        time.sleep(wait + 50 * timez.MILLISECOND);
    }
    return 0;
}

gc struct Chunk {
    seq: int,
    ids: [str]
}

gc struct ChunkDone {
    seq: int,
    last_id: str,
    granted: int,
    skipped: int,
    halt: str,
    error: str
}

fn grant_worker[C](l: Ledger[C], season_id: str, chunks: chan[Chunk], done: chan[ChunkDone]) -> int {
    while true {
        let got = chan_recv(chunks);
        guard let c = got else {
            return 0;
        }
        let f = l.store.grant_chunk;
        let r = f(l.store.context, season_id, c.ids);
        let last = c.ids[len(c.ids) - 1];
        if let res = r {
            chan_send(done, ChunkDone { seq: c.seq, last_id: last, granted: res.granted, skipped: res.skipped,
                                        halt: res.halt, error: "" });
        } else let e = err_of(r) {
            chan_send(done, ChunkDone { seq: c.seq, last_id: last, granted: 0, skipped: 0, halt: "", error: e });
        }
    }
    return 0;
}

// Advances the saved cursor only over a contiguous run of finished chunks,
// so a restart redoes at most the chunks that were in flight.
gc struct Frontier {
    next: int,
    finished: map[int]str,
    granted: int,
    skipped: int,
    halt: str,
    error: str
}

fn absorb(f: Frontier, d: ChunkDone) {
    if len(d.error) > 0 {
        if len(f.error) == 0 {
            f.error = d.error;
        }
        return;
    }
    if len(d.halt) > 0 && len(f.halt) == 0 {
        f.halt = d.halt;
    }
    f.granted += d.granted;
    f.skipped += d.skipped;
    f.finished[d.seq] = d.last_id;
}

fn advance[C](l: Ledger[C], season_id: str, f: Frontier) {
    let cursor = "";
    while has(f.finished, f.next) {
        cursor = f.finished[f.next];
        del(f.finished, f.next);
        f.next += 1;
    }
    if len(cursor) > 0 {
        let adv = l.store.grant_advance;
        let r = adv(l.store.context, season_id, cursor);
        if let _ok = r {
        } else let e = err_of(r) {
            signal(l, "warn", "grants.cursor_failed", 0, e);
        }
    }
}

fn drain_ready[C](l: Ledger[C], season_id: str, done: chan[ChunkDone], f: Frontier) {
    while true {
        let got = false;
        select {
            case let d = chan_recv(done) {
                if let x = d {
                    absorb(f, x);
                    got = true;
                }
            }
            default {}
        }
        if !got {
            break;
        }
    }
    advance(l, season_id, f);
}

// The rollover grant for one season: a producer keyset-paginates eligible
// accounts and N workers grant a chunk each, one transaction per chunk.
// Exactly 1 + N tasks; a full channel makes the producer wait, never drop.
pub fn run_rollover[C](l: Ledger[C], season_id: str) -> int {
    guard let lease_id = lease(l, lock_grants()) else {
        return 0;
    }
    let rf = l.store.grant_run;
    let rr = rf(l.store.context, season_id);
    guard let run = rr else let e = err_of(rr) {
        unlease(l, lease_id);
        signal(l, "critical", "grants.failed", 0, "grant run for " + season_id + ": " + e);
        return 0;
    }
    if run.finished {
        unlease(l, lease_id);
        return 0;
    }
    let started = timez.start_stopwatch();
    let workers = l.cfg.grant_workers;
    if workers < 1 {
        workers = 1;
    }
    let chunks: chan[Chunk] = make_chan(workers);
    // Room for every chunk that can be queued or in flight, so a worker
    // never blocks reporting while the producer blocks sending.
    let done: chan[ChunkDone] = make_chan(2 * workers + 2);
    let handles: [join[int]] = [];
    for i in 0..workers {
        push(handles, spawn grant_worker(l, season_id, chunks, done));
    }
    let fin: map[int]str = {};
    let f = Frontier { next: 0, finished: fin, granted: 0, skipped: 0, halt: "", error: "" };
    let cursor = run.last_account_id;
    let seq = 0;
    let eligible = l.store.eligible_after;
    while len(f.halt) == 0 && len(f.error) == 0 {
        let er = eligible(l.store.context, cursor, l.cfg.chunk_size);
        guard let ids = er else let e = err_of(er) {
            f.error = e;
            break;
        }
        if len(ids) == 0 {
            break;
        }
        chan_send(chunks, Chunk { seq: seq, ids: ids });
        seq += 1;
        cursor = ids[len(ids) - 1];
        drain_ready(l, season_id, done, f);
    }
    chan_close(chunks);
    for h in handles {
        let _j = join_wait(h);
    }
    drain_ready(l, season_id, done, f);
    if len(f.error) > 0 {
        unlease(l, lease_id);
        signal(l, "critical", "grants.failed", 0, "rollover for " + season_id + " stopped, resumes next tick: " + f.error);
        return 0;
    }
    let fr = l.store.grant_finish;
    let done_r = fr(l.store.context, season_id, f.halt);
    unlease(l, lease_id);
    kick_outbox(l);
    guard let summary = done_r else let e = err_of(done_r) {
        signal(l, "critical", "grants.failed", 0, "rollover for " + season_id + " could not finish: " + e);
        return 0;
    }
    let ms = started.elapsed() / timez.MILLISECOND;
    signal(l, "info", "grants.done", 0, "rollover for " + season_id + ": " + to_str(f.granted) + " granted, " +
           to_str(f.skipped) + " skipped, " + to_str(summary.granted) + " in the season, " + to_str(ms) + " ms");
    signal(l, "metric", "grants_total", f.granted, "");
    if len(f.halt) > 0 {
        signal(l, "critical", "grants.halted", 0, "rollover for " + season_id + " halted: " + f.halt);
    }
    return f.granted;
}

fn ticker(ticks: chan[int], every_ns: int) {
    while true {
        time.sleep(every_ns);
        select {
            case chan_send(ticks, 1) {}
            default {}
        }
    }
}

// One balance-check pass: the daily full scan when one is due, otherwise
// an incremental one; a requested run is claimed first.
pub fn recon_pass[C](l: Ledger[C], now: timez.Time) -> opt[ReconRun] {
    guard let id = lease(l, lock_recon()) else {
        return none;
    }
    let lf = l.store.last_full_recon;
    let full = true;
    let lr = lf(l.store.context);
    if let last = lr {
        if let at = last {
            full = now.sub(at) >= l.cfg.full_recon_every_ns;
        }
    }
    let run_f = l.store.recon_run;
    let r = run_f(l.store.context, full);
    unlease(l, id);
    guard let found = r else let e = err_of(r) {
        signal(l, "critical", "reconciliation.error", 0, "balance check could not run: " + e);
        return none;
    }
    guard let run = found else {
        return none;
    }
    if let good = run.ok {
        if !good {
            signal(l, "critical", "reconciliation.failed", 0, "balance check " + run.id + " failed; trading halted");
            signal(l, "metric", "reconciliation_failures_total", 1, "");
            kick_outbox(l);
        }
    }
    return some(run);
}

pub fn run_reconciler[C](l: Ledger[C]) -> int {
    let ticks: chan[int] = make_chan(1);
    spawn ticker(ticks, l.cfg.recon_every_ns);
    while true {
        let _p = recon_pass(l, l.clock.now());
        select {
            case let _t = chan_recv(ticks) {}
            case let _w = chan_recv(l.recon_wake) {}
        }
    }
    return 0;
}

pub fn aggregate_pass[C](l: Ledger[C]) -> int {
    guard let id = lease(l, lock_aggregate()) else {
        return 0;
    }
    let f = l.store.aggregate;
    let r = f(l.store.context);
    unlease(l, id);
    guard let n = r else let e = err_of(r) {
        signal(l, "warn", "aggregate.failed", 0, e);
        return 0;
    }
    return n;
}

pub fn run_aggregator[C](l: Ledger[C]) -> int {
    while true {
        let _n = aggregate_pass(l);
        time.sleep(l.cfg.aggregate_every_ns);
    }
    return 0;
}

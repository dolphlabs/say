import "timez";
import "../domain" as domain;

pub gc struct LedgerConfig {
    anchor: timez.Time,
    zone: timez.Zone,
    grant_workers: int,
    chunk_size: int,
    tick_cap_ns: int,
    late_grace_ns: int,
    recon_every_ns: int,
    full_recon_every_ns: int,
    aggregate_every_ns: int
}

pub fn default_config(anchor: timez.Time, zone: timez.Zone) -> LedgerConfig {
    return LedgerConfig {
        anchor: anchor, zone: zone, grant_workers: 4, chunk_size: 500, tick_cap_ns: 60 * timez.SECOND,
        late_grace_ns: 2 * timez.MINUTE, recon_every_ns: 5 * timez.MINUTE, full_recon_every_ns: timez.DAY,
        aggregate_every_ns: 2 * timez.SECOND
    };
}

// What background work reports instead of logging (the service does no
// I/O): platform/app drains these into the logger and the metrics.
// level is "info", "warn", "critical" or "metric"; a metric adds `value`
// to the counter or sets the gauge `name`.
pub gc struct Signal {
    level: str,
    name: str,
    value: int,
    text: str
}

pub gc struct Ledger[C] {
    store: LedgerStore[C],
    cfg: LedgerConfig,
    clock: timez.Clock,
    signals: chan[Signal],
    kicks: chan[int],
    recon_wake: chan[int],
    lock: mutex,
    dropped: int
}

pub fn new_ledger[C](store: LedgerStore[C], cfg: LedgerConfig, clock: timez.Clock) -> Ledger[C] {
    return Ledger[C] {
        store: store, cfg: cfg, clock: clock, signals: make_chan(1024), kicks: make_chan(1),
        recon_wake: make_chan(1), lock: make_mutex(), dropped: 0
    };
}

// A full channel drops the signal and counts it: background work never
// waits on its own logging.
pub fn signal[C](l: Ledger[C], level: str, name: str, value: int, text: str) {
    let sent = false;
    select {
        case chan_send(l.signals, Signal { level: level, name: name, value: value, text: text }) {
            sent = true;
        }
        default {}
    }
    if !sent {
        mutex_lock(l.lock);
        l.dropped += 1;
        mutex_unlock(l.lock);
    }
}

pub fn dropped_signals[C](l: Ledger[C]) -> int {
    mutex_lock(l.lock);
    let n = l.dropped;
    mutex_unlock(l.lock);
    return n;
}

// Wakes the outbox publisher; the table still holds the event if the kick
// is dropped.
pub fn kick_outbox[C](l: Ledger[C]) {
    select {
        case chan_send(l.kicks, 1) {}
        default {}
    }
}

pub enum Why {
    NotFound,
    BadRequest,
    Unavailable
}

pub gc struct Failed {
    why: Why,
    detail: str
}

fn fail(why: Why, detail: str) -> Failed {
    return Failed { why: why, detail: detail };
}

pub gc struct SeasonView {
    season: domain.Season,
    day: int,
    finalized: bool,
    provisional_reason: str,
    server_time: timez.Time
}

fn view[C](l: Ledger[C], s: domain.Season) -> SeasonView {
    let now = l.clock.now();
    let reason = "";
    if s.status != domain.finalized() {
        reason = "season is " + s.status + "; results are provisional until every market settles";
    }
    return SeasonView { season: s, day: domain.day_of(s, now, l.cfg.zone), finalized: s.status == domain.finalized(),
                        provisional_reason: reason, server_time: now };
}

pub fn current_season[C](l: Ledger[C]) -> result[opt[SeasonView], Failed] {
    let f = l.store.current;
    let r = f(l.store.context);
    guard let found = r else let e = err_of(r) {
        return err(fail(Why.Unavailable, e));
    }
    let none_view: opt[SeasonView] = none;
    guard let s = found else {
        return ok(none_view);
    }
    return ok(some(view(l, s)));
}

pub fn season[C](l: Ledger[C], ordinal: int) -> result[SeasonView, Failed] {
    if ordinal < 1 {
        return err(fail(Why.BadRequest, "season ordinal must be 1 or more"));
    }
    let f = l.store.by_ordinal;
    let r = f(l.store.context, ordinal);
    guard let found = r else let e = err_of(r) {
        return err(fail(Why.Unavailable, e));
    }
    guard let s = found else {
        return err(fail(Why.NotFound, "no season " + to_str(ordinal)));
    }
    return ok(view(l, s));
}

pub fn current_season_end[C](l: Ledger[C]) -> result[opt[timez.Time], str] {
    let r = current_season(l);
    guard let found = r else let e = err_of(r) {
        return err(e.detail);
    }
    let none_end: opt[timez.Time] = none;
    guard let v = found else {
        return ok(none_end);
    }
    return ok(some(v.season.ends_at));
}

// "current", "" or an ordinal; 0 means the active season.
pub fn season_selector(raw: str) -> result[int, Failed] {
    if len(raw) == 0 || raw == "current" {
        return ok(0);
    }
    let n = to_int(raw) ?? 0;
    if n < 1 {
        return err(fail(Why.BadRequest, "season must be 'current' or a season number"));
    }
    return ok(n);
}

pub fn balance[C](l: Ledger[C], account_id: str, ordinal: int) -> result[Balance, Failed] {
    let f = l.store.balance;
    let r = f(l.store.context, account_id, ordinal);
    guard let found = r else let e = err_of(r) {
        return err(fail(Why.Unavailable, e));
    }
    guard let b = found else {
        return err(fail(Why.NotFound, "no such season"));
    }
    return ok(b);
}

pub fn ledger_page[C](l: Ledger[C], account_id: str, ordinal: int, cursor: str, limit: int) -> result[LedgerPage, Failed] {
    if limit < 1 || limit > 100 {
        return err(fail(Why.BadRequest, "limit must be 1-100"));
    }
    let f = l.store.ledger_page;
    let r = f(l.store.context, account_id, ordinal, cursor, limit);
    guard let found = r else let e = err_of(r) {
        if e == "bad cursor" {
            return err(fail(Why.BadRequest, e));
        }
        return err(fail(Why.Unavailable, e));
    }
    guard let page = found else {
        return err(fail(Why.NotFound, "no such season"));
    }
    return ok(page);
}

pub gc struct Summary {
    season: opt[SeasonView],
    balance: opt[Balance]
}

fn fetch_season[C](l: Ledger[C]) -> result[opt[SeasonView], Failed] {
    return current_season(l);
}

fn fetch_balance[C](l: Ledger[C], account_id: str) -> result[Balance, Failed] {
    return balance(l, account_id, 0);
}

// The header's two reads, fetched concurrently.
pub fn summary[C](l: Ledger[C], account_id: str) -> result[Summary, Failed] {
    let hs = spawn fetch_season(l);
    let hb = spawn fetch_balance(l, account_id);
    let sr = join_wait(hs);
    let br = join_wait(hb);
    guard let s_outer = sr else let e = err_of(sr) {
        return err(fail(Why.Unavailable, e));
    }
    guard let b_outer = br else let e = err_of(br) {
        return err(fail(Why.Unavailable, e));
    }
    guard let season_view = s_outer else let e = err_of(s_outer) {
        return err(e);
    }
    let none_b: opt[Balance] = none;
    let bal = none_b;
    if let b = b_outer {
        bal = some(b);
    } else let e = err_of(b_outer) {
        if e.why != Why.NotFound {
            return err(e);
        }
    }
    return ok(Summary { season: season_view, balance: bal });
}

pub fn halt_state[C](l: Ledger[C]) -> result[Halt, Failed] {
    let f = l.store.halt_state;
    let r = f(l.store.context);
    guard let h = r else let e = err_of(r) {
        return err(fail(Why.Unavailable, e));
    }
    return ok(h);
}

pub fn clear_halt[C](l: Ledger[C], actor: str, reason: str) -> result[bool, Failed] {
    if len(reason) < 3 || len(reason) > 500 {
        return err(fail(Why.BadRequest, "reason must be 3-500 characters"));
    }
    let f = l.store.halt_clear;
    let r = f(l.store.context, actor, reason);
    guard let _ok = r else let e = err_of(r) {
        return err(fail(Why.Unavailable, e));
    }
    signal(l, "warn", "trading_halt.cleared", 0, "trading halt cleared by " + actor + ": " + reason);
    return ok(true);
}

pub fn latest_recon[C](l: Ledger[C]) -> result[opt[ReconRun], Failed] {
    let f = l.store.recon_latest;
    let r = f(l.store.context);
    guard let run = r else let e = err_of(r) {
        return err(fail(Why.Unavailable, e));
    }
    return ok(run);
}

// Queues a full run for the runner and wakes it; the id comes back at once.
pub fn request_recon[C](l: Ledger[C], actor: str) -> result[str, Failed] {
    let f = l.store.recon_request;
    let r = f(l.store.context, actor);
    guard let id = r else let e = err_of(r) {
        return err(fail(Why.Unavailable, e));
    }
    select {
        case chan_send(l.recon_wake, 1) {}
        default {}
    }
    return ok(id);
}

pub fn propose_policy[C](l: Ledger[C], amount: int, cap: int, operator: str) -> result[str, Failed] {
    if amount <= 0 || cap < amount {
        return err(fail(Why.BadRequest, "amount must be positive and the cap at least the amount"));
    }
    let f = l.store.policy_propose;
    let r = f(l.store.context, amount, cap, operator);
    guard let id = r else let e = err_of(r) {
        return err(fail(Why.BadRequest, e));
    }
    return ok(id);
}

pub fn approve_policy[C](l: Ledger[C], policy_id: str, operator: str) -> result[PolicyView, Failed] {
    let f = l.store.policy_approve;
    let r = f(l.store.context, policy_id, operator);
    guard let v = r else let e = err_of(r) {
        return err(fail(Why.BadRequest, e));
    }
    return ok(v);
}

pub fn policies[C](l: Ledger[C]) -> result[[PolicyView], Failed] {
    let f = l.store.policies;
    let r = f(l.store.context);
    guard let vs = r else let e = err_of(r) {
        return err(fail(Why.Unavailable, e));
    }
    return ok(vs);
}

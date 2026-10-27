import "strings";
import "time";
import "timez";
import "../domain" as domain;

pub gc struct Markets[C] {
    store: MarketStore[C], new_id: fn() -> str, clock: timez.Clock,
    lock: mutex, current: opt[Snapshot], generation: int,
    kicks: chan[int], problems: chan[str], history: [Snapshot],
    snapshot_every_ns: int, close_poll_ns: int, close_workers: int, history_generations: int,
    refresh_lock: mutex, policies: map[str]MarketPolicy
}

pub fn new_markets[C](store: MarketStore[C], new_id: fn() -> str, clock: timez.Clock) -> Markets[C] {
    let policies: map[str]MarketPolicy={};
    return Markets[C] { store: store, new_id: new_id, clock: clock, lock: make_mutex(), current: none,
        generation: 0, kicks: make_chan(1), problems: make_chan(128), history: [],
        snapshot_every_ns:1800000000,close_poll_ns:100000000,close_workers:8,history_generations:32,
        refresh_lock:make_mutex(),policies:policies };
}

pub fn uuid(value: str) -> bool {
    if len(value) != 36 { return false; }
    let b = to_bytes(value);
    for i in 0..36 {
        if i == 8 || i == 13 || i == 18 || i == 23 { if b[i] != 45 { return false; } }
        else if !((b[i] >= 48 && b[i] <= 57) || (b[i] >= 97 && b[i] <= 102)) { return false; }
    }
    return true;
}

pub fn mutate[C](s: Markets[C], actor_id: str, action: str, id: str, version: int,
                 patch: domain.Patch, reason: str) -> result[domain.Market, Failed] {
    if !uuid(actor_id) || (action != "create" && !uuid(id)) { return err(failure("BAD_REQUEST", "invalid identifier")); }
    if action != "create" && version < 1 { return err(failure("STALE_VERSION", "")); }
    for value in [patch.category_id, patch.season_id, patch.resolution_source_id] {
        if let text = value { if len(text) > 0 && !uuid(text) { return err(failure("BAD_REQUEST", "invalid linked identifier")); } }
    }
    if action == "clarify" || action == "suspend" || action == "resume" || action == "reject" || action == "request-changes" {
        if domain.unicode_length(strings.trim(reason)) < 3 || domain.unicode_length(reason) > 1000 {
            return err(failure("BAD_REQUEST", "A reason of 3–1000 characters is required."));
        }
    }
    let market_id = id;
    if action == "create" { let make = s.new_id; market_id = make(); }
    let apply = s.store.mutate;
    let changed = apply(s.store.context, Command { action: action, id: market_id, actor_id: actor_id,
        version: version, patch: patch, reason: reason, now: s.clock.now().unix_milli() });
    if let _m = changed { select { case chan_send(s.kicks, 1) {} default {} } }
    return changed;
}

pub fn get[C](s: Markets[C], selector: str, actor: str) -> result[domain.Market, Failed] {
    if len(actor)==0 {
        mutex_lock(s.lock); let cached=s.current; mutex_unlock(s.lock);
        if let data=cached { if let m=public_market(data,selector) { return ok(m); } }
    }
    let find = s.store.find;
    let r = find(s.store.context, selector, actor);
    guard let found = r else let f = err_of(r) { return err(f); }
    guard let market = found else { return err(failure("NOT_FOUND", "")); }
    return ok(market);
}

pub fn snapshot[C](s: Markets[C]) -> result[Snapshot, Failed] {
    mutex_lock(s.lock);
    let found = s.current;
    mutex_unlock(s.lock);
    guard let data = found else { return err(failure("UNAVAILABLE", "Market snapshot is warming.")); }
    return ok(data);
}

pub fn refresh[C](s: Markets[C]) -> result[int, str] {
    if !mutex_trylock(s.refresh_lock) {
        mutex_lock(s.lock); let current=s.generation; mutex_unlock(s.lock);
        return ok(current);
    }
    let read = s.store.snapshot;
    let r = read(s.store.context, s.clock.now().unix_milli());
    guard let data = r else let e = err_of(r) { mutex_unlock(s.refresh_lock); return err(e); }
    mutex_lock(s.lock);
    s.generation += 1;
    data.generation = s.generation;
    s.current = some(data);
    let kept: [Snapshot] = [];
    let from = 0;
    if len(s.history) >= s.history_generations { from = len(s.history) - s.history_generations + 1; }
    for i in from..len(s.history) { push(kept,s.history[i]); }
    push(kept,data);
    s.history=kept;
    mutex_unlock(s.lock);
    mutex_unlock(s.refresh_lock);
    return ok(data.generation);
}

fn report[C](s: Markets[C], message: str) {
    select { case chan_send(s.problems, message) {} default {} }
}

pub fn run_snapshots[C](s: Markets[C]) -> int {
    let built = 0;
    while true {
        let dirty=false;
        select { case let _k=chan_recv(s.kicks) { dirty=true; } default {} }
        if built==0 || dirty || time.mono()-built>=s.snapshot_every_ns {
            let r = refresh(s);
            if let _n = r {} else let e = err_of(r) { report(s, e); }
            built=time.mono() as int;
        }
        time.sleep(50000000);
    }
    return 0;
}

pub fn run_scheduler[C](s: Markets[C]) -> int {
    let acquire = s.store.lease_try;
    let release = s.store.lease_release;
    let due = s.store.due;
    let apply = s.store.mutate;
    while true {
        let lr = acquire(s.store.context, 7310010);
        if let found = lr {
            if let lease = found {
                let healthy = true;
                while healthy {
                    let now = s.clock.now().unix_milli();
                    let r = due(s.store.context, now);
                    if let rows = r {
                        healthy=advance_batch(s,rows,now);
                    } else let e = err_of(r) { healthy = false; report(s, e); }
                    time.sleep(s.close_poll_ns);
                }
                release(s.store.context, lease);
            }
        } else let e = err_of(lr) { report(s, e); }
        time.sleep(250000000);
    }
    return 0;
}

fn advance_one[C](s: Markets[C],m: domain.Market,now: int) -> result[bool,str] {
    let apply=s.store.mutate;
    let changed=apply(s.store.context,Command { action:"advance",id:m.id,actor_id:"",version:m.version,
        patch:domain.empty_patch(),reason:"scheduled lifecycle",now:now });
    guard let _m=changed else let f=err_of(changed) {
        if f.code=="STALE_VERSION" || f.code=="INVALID_TRANSITION" { return ok(false); }
        return err(f.code+": "+f.detail);
    }
    return ok(true);
}

pub fn advance_batch[C](s: Markets[C],rows: [domain.Market],now: int) -> bool {
    let offset=0;
    let healthy=true;
    while offset<len(rows) {
        let end=offset+s.close_workers; if end>len(rows) { end=len(rows); }
        let jobs: [join[result[bool,str]]]=[];
        for i in offset..end { push(jobs,spawn advance_one(s,rows[i],now)); }
        for task in jobs {
            let joined=join_wait(task);
            if let r=joined {
                if let _ok=r {} else let e=err_of(r) { report(s,e); healthy=false; }
            } else let e=err_of(joined) { report(s,e); healthy=false; }
        }
        offset=end;
    }
    return healthy;
}

pub fn trading_state[C](s: Markets[C], id: str) -> result[str, Failed] {
    let r = get(s, id, "");
    guard let m = r else let f = err_of(r) { return err(f); }
    if m.close_at <= s.clock.now().unix_milli() || m.status == "CLOSED" { return ok("CLOSED"); }
    if m.status == "OPEN" || m.status == "SUSPENDED" { return ok(m.status); }
    return ok("NOT_TRADABLE");
}

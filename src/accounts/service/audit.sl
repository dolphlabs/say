import "time";

// Auth events go through a bounded channel to one writer task, which
// inserts them in batches. A full channel drops the event and counts it:
// a login never waits on the audit trail.
pub gc struct AuditLog {
    events: chan[AuditEvent],
    lock: mutex,
    dropped: int,
    written: int,
    failed: int
}

pub fn new_audit_log(capacity: int) -> AuditLog {
    return AuditLog { events: make_chan(capacity), lock: make_mutex(), dropped: 0, written: 0, failed: 0 };
}

pub fn audit_batch_size() -> int {
    return 100;
}

pub fn audit_flush_ms() -> int {
    return 250;
}

pub fn record(l: AuditLog, ev: AuditEvent) {
    let sent = false;
    select {
        case chan_send(l.events, ev) {
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

pub fn audit_dropped(l: AuditLog) -> int {
    mutex_lock(l.lock);
    let n = l.dropped;
    mutex_unlock(l.lock);
    return n;
}

pub fn audit_written(l: AuditLog) -> int {
    mutex_lock(l.lock);
    let n = l.written;
    mutex_unlock(l.lock);
    return n;
}

fn audit_event[C](a: Auth[C], actor_id: str, action: str, m: Meta, detail_json: str) {
    record(a.audit, AuditEvent { actor_id: actor_id, action: action, ip: m.ip, user_agent: m.user_agent, detail_json: detail_json });
}

fn ticker(ticks: chan[int], every_ms: int) {
    while true {
        time.sleep(every_ms * 1000000);
        let sent = false;
        select {
            case chan_send(ticks, 1) {
                sent = true;
            }
            default {}
        }
    }
}

fn flush[C](a: Auth[C], batch: [AuditEvent]) -> [AuditEvent] {
    let empty: [AuditEvent] = [];
    if len(batch) == 0 {
        return empty;
    }
    let f = a.store.insert_audit;
    let r = f(a.store.context, batch);
    mutex_lock(a.audit.lock);
    if let _n = r {
        a.audit.written += len(batch);
    } else {
        a.audit.failed += len(batch);
    }
    mutex_unlock(a.audit.lock);
    if let _n = r {
    } else let e = err_of(r) {
        report(a, "audit batch of " + to_str(len(batch)) + " lost: " + e);
    }
    return empty;
}

// Runs until the event channel closes: flushes every 100 events or every
// 250 ms, whichever comes first.
pub fn run_audit_writer[C](a: Auth[C]) -> int {
    let ticks: chan[int] = make_chan(1);
    spawn ticker(ticks, audit_flush_ms());
    let batch: [AuditEvent] = [];
    while true {
        let closed = false;
        select {
            case let got = chan_recv(a.audit.events) {
                if let ev = got {
                    push(batch, ev);
                    if len(batch) >= audit_batch_size() {
                        batch = flush(a, batch);
                    }
                } else {
                    closed = true;
                }
            }
            case let _t = chan_recv(ticks) {
                batch = flush(a, batch);
            }
        }
        if closed {
            batch = flush(a, batch);
            return 0;
        }
    }
    return 0;
}

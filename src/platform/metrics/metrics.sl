import "builder";

// Counters and gauges in process memory, served as Prometheus text.
// Names may carry labels: `season_transitions_total{to="ACTIVE"}`.
pub gc struct Registry {
    lock: mutex,
    counters: map[str]int,
    gauges: map[str]int
}

pub fn new_registry() -> Registry {
    let c: map[str]int = {};
    let g: map[str]int = {};
    return Registry { lock: make_mutex(), counters: c, gauges: g };
}

pub fn add(r: Registry, name: str, n: int) {
    mutex_lock(r.lock);
    let v = 0;
    if has(r.counters, name) {
        v = r.counters[name];
    }
    r.counters[name] = v + n;
    mutex_unlock(r.lock);
}

pub fn set(r: Registry, name: str, n: int) {
    mutex_lock(r.lock);
    r.gauges[name] = n;
    mutex_unlock(r.lock);
}

pub fn value(r: Registry, name: str) -> int {
    mutex_lock(r.lock);
    let v = 0;
    if has(r.counters, name) {
        v = r.counters[name];
    } else if has(r.gauges, name) {
        v = r.gauges[name];
    }
    mutex_unlock(r.lock);
    return v;
}

fn sorted(xs: [str]) -> [str] {
    for i in 1..len(xs) {
        let j = i;
        while j > 0 && xs[j] < xs[j - 1] {
            let t = xs[j];
            xs[j] = xs[j - 1];
            xs[j - 1] = t;
            j = j - 1;
        }
    }
    return xs;
}

pub fn render(r: Registry) -> str {
    let b = builder.new_str();
    mutex_lock(r.lock);
    let names: [str] = [];
    for k, _v in r.counters {
        push(names, k);
    }
    for k in sorted(names) {
        b.write(k).write(" ").write_int(r.counters[k]).write("\n");
    }
    let gnames: [str] = [];
    for k, _v in r.gauges {
        push(gnames, k);
    }
    for k in sorted(gnames) {
        b.write(k).write(" ").write_int(r.gauges[k]).write("\n");
    }
    mutex_unlock(r.lock);
    return b.finish();
}

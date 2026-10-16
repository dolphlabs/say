import "../domain" as domain;

pub gc struct Memory {
    lock: mutex,
    rows: map[str]domain.Account,
    by_email: map[str]str,
    order: [str]
}

fn new_memory() -> Memory {
    let rows: map[str]domain.Account = {};
    let by_email: map[str]str = {};
    let order: [str] = [];
    return Memory { lock: make_mutex(), rows: rows, by_email: by_email, order: order };
}

fn memory_insert(m: Memory, n: domain.Account) -> result[bool, str] {
    mutex_lock(m.lock);
    let fresh = !has(m.rows, n.id);
    if fresh {
        m.rows[n.id] = n;
        push(m.order, n.id);
        if let em = n.email {
            m.by_email[em] = n.id;
        }
    }
    mutex_unlock(m.lock);
    if !fresh {
        return err("account " + n.id + " already exists");
    }
    return ok(true);
}

fn memory_find(m: Memory, tenant_id: str, id: str) -> result[opt[domain.Account], str] {
    mutex_lock(m.lock);
    let found: opt[domain.Account] = none;
    if has(m.rows, id) {
        found = some(m.rows[id]);
    }
    mutex_unlock(m.lock);
    return ok(found);
}

fn memory_find_by_email(m: Memory, tenant_id: str, email: str) -> result[opt[domain.Account], str] {
    mutex_lock(m.lock);
    let found: opt[domain.Account] = none;
    if has(m.by_email, email) {
        let id = m.by_email[email];
        if has(m.rows, id) {
            found = some(m.rows[id]);
        }
    }
    mutex_unlock(m.lock);
    return ok(found);
}

fn memory_list(m: Memory, tenant_id: str, offset: int, limit: int) -> result[[domain.Account], str] {
    let out: [domain.Account] = [];
    let skipped = 0;
    mutex_lock(m.lock);
    for id in m.order {
        let n = m.rows[id];
        if len(out) < limit {
            if skipped < offset {
                skipped = skipped + 1;
            } else {
                push(out, n);
            }
        }
    }
    mutex_unlock(m.lock);
    return ok(out);
}

import "strings";
import "../domain" as domain;
import "../service" as service;

pub gc struct Memory {
    lock: mutex,
    rows: map[str]domain.Account,
    by_username: map[str]str,
    by_email: map[str]str,
    by_phone: map[str]str,
    order: [str]
}

fn new_memory() -> Memory {
    let rows: map[str]domain.Account = {};
    let by_username: map[str]str = {};
    let by_email: map[str]str = {};
    let by_phone: map[str]str = {};
    let order: [str] = [];
    return Memory {
        lock: make_mutex(),
        rows: rows,
        by_username: by_username,
        by_email: by_email,
        by_phone: by_phone,
        order: order
    };
}

fn memory_insert(m: Memory, n: domain.Account) -> result[bool, str] {
    mutex_lock(m.lock);
    let fresh = !has(m.rows, n.id);
    if fresh {
        m.rows[n.id] = n;
        push(m.order, n.id);
        if let u = n.username {
            m.by_username[strings.to_lower(u)] = n.id;
        }
        if let em = n.email {
            m.by_email[strings.to_lower(em)] = n.id;
        }
        if let ph = n.phone_number {
            m.by_phone[ph] = n.id;
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

fn memory_find_by_username(m: Memory, tenant_id: str, username: str) -> result[opt[domain.Account], str] {
    mutex_lock(m.lock);
    let found: opt[domain.Account] = none;
    let key = strings.to_lower(username);
    if has(m.by_username, key) {
        let id = m.by_username[key];
        if has(m.rows, id) {
            found = some(m.rows[id]);
        }
    }
    mutex_unlock(m.lock);
    return ok(found);
}

fn memory_find_by_email(m: Memory, tenant_id: str, email: str) -> result[opt[domain.Account], str] {
    mutex_lock(m.lock);
    let found: opt[domain.Account] = none;
    let key = strings.to_lower(email);
    if has(m.by_email, key) {
        let id = m.by_email[key];
        if has(m.rows, id) {
            found = some(m.rows[id]);
        }
    }
    mutex_unlock(m.lock);
    return ok(found);
}

fn memory_find_by_phone(m: Memory, tenant_id: str, phone: str) -> result[opt[domain.Account], str] {
    mutex_lock(m.lock);
    let found: opt[domain.Account] = none;
    if has(m.by_phone, phone) {
        let id = m.by_phone[phone];
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

fn memory_record_signup_audit(m: Memory, tenant_id: str, account_id: str, meta: service.AuditMeta) -> result[bool, str] {
    return ok(true);
}

fn memory_record_login_audit(m: Memory, tenant_id: str, account_id: str, meta: service.AuditMeta) -> result[bool, str] {
    return ok(true);
}

fn memory_record_logout_audit(m: Memory, tenant_id: str, account_id: str, meta: service.AuditMeta) -> result[bool, str] {
    return ok(true);
}

fn memory_verify_email(m: Memory, tenant_id: str, email: str) -> result[bool, str] {
    mutex_lock(m.lock);
    let key = strings.to_lower(email);
    if has(m.by_email, key) {
        let id = m.by_email[key];
        if has(m.rows, id) {
            let a = m.rows[id];
            let updated = domain.Account {
                id: a.id,
                username: a.username,
                email: a.email,
                phone_number: a.phone_number,
                password_hash: a.password_hash,
                auth_provider: a.auth_provider,
                status: a.status,
                kind: a.kind,
                beneficial_owner_group: a.beneficial_owner_group,
                email_verified_at: some("2026-10-16T00:00:00Z"),
                verified_at: some("2026-10-16T00:00:00Z"),
                age_confirmed_at: a.age_confirmed_at,
                created_at: a.created_at
            };
            m.rows[id] = updated;
            mutex_unlock(m.lock);
            return ok(true);
        }
    }
    mutex_unlock(m.lock);
    return ok(false);
}

fn memory_confirm_age(m: Memory, tenant_id: str, account_id: str) -> result[bool, str] {
    mutex_lock(m.lock);
    if has(m.rows, account_id) {
        let a = m.rows[account_id];
        let updated = domain.Account {
            id: a.id,
            username: a.username,
            email: a.email,
            phone_number: a.phone_number,
            password_hash: a.password_hash,
            auth_provider: a.auth_provider,
            status: a.status,
            kind: a.kind,
            beneficial_owner_group: a.beneficial_owner_group,
            email_verified_at: a.email_verified_at,
            verified_at: a.verified_at,
            age_confirmed_at: some("2026-10-16T00:00:00Z"),
            created_at: a.created_at
        };
        m.rows[account_id] = updated;
        mutex_unlock(m.lock);
        return ok(true);
    }
    mutex_unlock(m.lock);
    return ok(false);
}

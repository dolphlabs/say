import "strings";
import "../domain" as domain;

gc struct FakeStore {
    calls: [str],
    rows: map[str]domain.Account,
    failure: str
}

fn fake_store() -> FakeStore {
    let calls: [str] = [];
    let rows: map[str]domain.Account = {};
    return FakeStore { calls: calls, rows: rows, failure: "" };
}

fn fake_insert(f: FakeStore, n: domain.Account) -> result[bool, str] {
    push(f.calls, "insert " + n.id);
    if len(f.failure) > 0 { return err(f.failure); }
    f.rows[n.id] = n;
    return ok(true);
}

fn fake_find(f: FakeStore, tenant_id: str, id: str) -> result[opt[domain.Account], str] {
    push(f.calls, "find " + id);
    if len(f.failure) > 0 { return err(f.failure); }
    let absent: opt[domain.Account] = none;
    if !has(f.rows, id) { return ok(absent); }
    return ok(some(f.rows[id]));
}

fn fake_find_by_username(f: FakeStore, tenant_id: str, username: str) -> result[opt[domain.Account], str] {
    push(f.calls, "find_by_username " + username);
    if len(f.failure) > 0 { return err(f.failure); }
    let absent: opt[domain.Account] = none;
    let target = strings.to_lower(username);
    for _id, a in f.rows {
        if let u = a.username {
            if strings.to_lower(u) == target {
                return ok(some(a));
            }
        }
    }
    return ok(absent);
}

fn fake_find_by_email(f: FakeStore, tenant_id: str, email: str) -> result[opt[domain.Account], str] {
    push(f.calls, "find_by_email " + email);
    if len(f.failure) > 0 { return err(f.failure); }
    let absent: opt[domain.Account] = none;
    let target = strings.to_lower(email);
    for _id, a in f.rows {
        if let em = a.email {
            if strings.to_lower(em) == target {
                return ok(some(a));
            }
        }
    }
    return ok(absent);
}

fn fake_find_by_phone(f: FakeStore, tenant_id: str, phone: str) -> result[opt[domain.Account], str] {
    push(f.calls, "find_by_phone " + phone);
    if len(f.failure) > 0 { return err(f.failure); }
    let absent: opt[domain.Account] = none;
    for _id, a in f.rows {
        if let ph = a.phone_number {
            if ph == phone {
                return ok(some(a));
            }
        }
    }
    return ok(absent);
}

fn fake_list(f: FakeStore, tenant_id: str, offset: int, limit: int) -> result[[domain.Account], str] {
    push(f.calls, "list " + tenant_id);
    if len(f.failure) > 0 { return err(f.failure); }
    let out: [domain.Account] = [];
    for _k, n in f.rows {
        push(out, n);
    }
    return ok(out);
}

fn fake_record_signup_audit(f: FakeStore, tenant_id: str, account_id: str, meta: AuditMeta) -> result[bool, str] {
    push(f.calls, "audit " + account_id);
    return ok(true);
}

fn fake_record_login_audit(f: FakeStore, tenant_id: str, account_id: str, meta: AuditMeta) -> result[bool, str] {
    push(f.calls, "login_audit " + account_id);
    return ok(true);
}

fn fake_record_logout_audit(f: FakeStore, tenant_id: str, account_id: str, meta: AuditMeta) -> result[bool, str] {
    push(f.calls, "logout_audit " + account_id);
    return ok(true);
}

fn fake_verify_email(f: FakeStore, tenant_id: str, email: str) -> result[bool, str] {
    push(f.calls, "verify_email " + email);
    if len(f.failure) > 0 { return err(f.failure); }
    let target = strings.to_lower(email);
    for id, a in f.rows {
        if let em = a.email {
            if strings.to_lower(em) == target {
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
                f.rows[id] = updated;
                return ok(true);
            }
        }
    }
    return ok(false);
}

fn fake_confirm_age(f: FakeStore, tenant_id: str, account_id: str) -> result[bool, str] {
    push(f.calls, "confirm_age " + account_id);
    if len(f.failure) > 0 { return err(f.failure); }
    if has(f.rows, account_id) {
        let a = f.rows[account_id];
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
        f.rows[account_id] = updated;
        return ok(true);
    }
    return ok(false);
}

fn fixed_id() -> str {
    return "acc_1";
}

fn fake_accounts(f: FakeStore) -> Accounts[FakeStore] {
    return new_accounts(AccountStore[FakeStore] {
        context: f,
        insert: fake_insert,
        find: fake_find,
        find_by_username: fake_find_by_username,
        find_by_email: fake_find_by_email,
        find_by_phone: fake_find_by_phone,
        list: fake_list,
        record_signup_audit: fake_record_signup_audit,
        record_login_audit: fake_record_login_audit,
        record_logout_audit: fake_record_logout_audit,
        verify_email: fake_verify_email,
        confirm_age: fake_confirm_age
    }, fixed_id);
}

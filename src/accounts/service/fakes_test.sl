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

fn fake_find_by_email(f: FakeStore, tenant_id: str, email: str) -> result[opt[domain.Account], str] {
    push(f.calls, "find_by_email " + email);
    if len(f.failure) > 0 { return err(f.failure); }
    let absent: opt[domain.Account] = none;
    for _id, a in f.rows {
        if let em = a.email {
            if em == email {
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

fn fixed_id() -> str {
    return "acc_1";
}

fn fake_accounts(f: FakeStore) -> Accounts[FakeStore] {
    return new_accounts(AccountStore[FakeStore] {
        context: f,
        insert: fake_insert,
        find: fake_find,
        find_by_email: fake_find_by_email,
        list: fake_list
    }, fixed_id);
}

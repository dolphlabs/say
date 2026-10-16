import "../domain" as domain;

pub gc struct Accounts[C] {
    store: AccountStore[C],
    new_id: fn() -> str
}

pub enum Why {
    Invalid,
    NotFound,
    Unavailable
}

pub gc struct Failed {
    why: Why,
    problems: [domain.Problem],
    detail: str
}

pub fn new_accounts[C](store: AccountStore[C], new_id: fn() -> str) -> Accounts[C] {
    return Accounts[C] { store: store, new_id: new_id };
}

fn failed(why: Why, detail: str) -> Failed {
    let none_yet: [domain.Problem] = [];
    return Failed { why: why, problems: none_yet, detail: detail };
}

pub fn create[C](s: Accounts[C], tenant_id: str, email: opt[str], password_hash: opt[str], auth_provider: str) -> result[domain.Account, Failed] {
    let p = domain.validate_new(email, auth_provider);
    if len(p) > 0 {
        return err(Failed { why: Why.Invalid, problems: p, detail: "" });
    }
    let make_id = s.new_id;
    let none_str: opt[str] = none;
    let n = domain.Account {
        id: make_id(),
        email: email,
        password_hash: password_hash,
        auth_provider: auth_provider,
        status: "ACTIVE",
        kind: "USER",
        beneficial_owner_group: none_str,
        email_verified_at: none_str,
        verified_at: none_str,
        age_confirmed_at: none_str,
        created_at: ""
    };
    let insert = s.store.insert;
    let r = insert(s.store.context, n);
    guard let _ok = r else let e = err_of(r) {
        return err(failed(Why.Unavailable, e));
    }
    return ok(n);
}

pub fn get[C](s: Accounts[C], tenant_id: str, id: str) -> result[domain.Account, Failed] {
    let find = s.store.find;
    let r = find(s.store.context, tenant_id, id);
    guard let found = r else let e = err_of(r) {
        return err(failed(Why.Unavailable, e));
    }
    guard let n = found else {
        return err(failed(Why.NotFound, ""));
    }
    return ok(n);
}

pub fn get_by_email[C](s: Accounts[C], tenant_id: str, email: str) -> result[domain.Account, Failed] {
    let find = s.store.find_by_email;
    let r = find(s.store.context, tenant_id, email);
    guard let found = r else let e = err_of(r) {
        return err(failed(Why.Unavailable, e));
    }
    guard let n = found else {
        return err(failed(Why.NotFound, ""));
    }
    return ok(n);
}

pub fn list[C](s: Accounts[C], tenant_id: str, offset: int, limit: int) -> result[[domain.Account], Failed] {
    let all = s.store.list;
    let r = all(s.store.context, tenant_id, offset, limit);
    guard let rows = r else let e = err_of(r) {
        return err(failed(Why.Unavailable, e));
    }
    return ok(rows);
}

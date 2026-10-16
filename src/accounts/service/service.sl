import "../domain" as domain;

pub gc struct Accounts[C] {
    store: AccountStore[C],
    new_id: fn() -> str
}

pub enum Why {
    Invalid,
    NotFound,
    Unavailable,
    UsernameTaken,
    EmailTaken,
    PhoneTaken
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

pub fn check_username[C](s: Accounts[C], tenant_id: str, username: str) -> result[bool, Failed] {
    let uv = domain.validate_username(username);
    if let problem = uv {
        let ps: [domain.Problem] = [domain.Problem { field: "username", reason: problem }];
        return err(Failed { why: Why.Invalid, problems: ps, detail: problem });
    }
    let find = s.store.find_by_username;
    let r = find(s.store.context, tenant_id, username);
    guard let found = r else let e = err_of(r) {
        return err(failed(Why.Unavailable, e));
    }
    if let _existing = found {
        return err(failed(Why.UsernameTaken, "username is already taken"));
    }
    return ok(true);
}

pub fn create_with_password[C](s: Accounts[C], tenant_id: str, username: str, email: str, raw_password: str, phone_number: opt[str], audit_meta: AuditMeta) -> result[domain.Account, Failed] {
    let ps: [domain.Problem] = [];
    if let up = domain.validate_username(username) {
        push(ps, domain.Problem { field: "username", reason: up });
    }
    if let ep = domain.validate_email(email) {
        push(ps, domain.Problem { field: "email", reason: ep });
    }
    if let pp = domain.validate_password(raw_password) {
        push(ps, domain.Problem { field: "password", reason: pp });
    }
    if let phone = phone_number {
        if let php = domain.validate_phone_number(phone) {
            push(ps, domain.Problem { field: "phone_number", reason: php });
        }
    }
    if len(ps) > 0 {
        return err(Failed { why: Why.Invalid, problems: ps, detail: "validation failed" });
    }

    let find_u = s.store.find_by_username;
    let u_res = find_u(s.store.context, tenant_id, username);
    guard let existing_u = u_res else let e = err_of(u_res) {
        return err(failed(Why.Unavailable, e));
    }
    if let _u = existing_u {
        return err(failed(Why.UsernameTaken, "username is already taken"));
    }

    let find_e = s.store.find_by_email;
    let e_res = find_e(s.store.context, tenant_id, email);
    guard let existing_e = e_res else let e = err_of(e_res) {
        return err(failed(Why.Unavailable, e));
    }
    if let _e = existing_e {
        return err(failed(Why.EmailTaken, "email is already registered"));
    }

    if let phone = phone_number {
        let find_p = s.store.find_by_phone;
        let p_res = find_p(s.store.context, tenant_id, phone);
        guard let existing_p = p_res else let e = err_of(p_res) {
            return err(failed(Why.Unavailable, e));
        }
        if let _p = existing_p {
            return err(failed(Why.PhoneTaken, "phone number is already registered"));
        }
    }

    let hash_res = hash_password(raw_password);
    guard let pass_hash = hash_res else let e = err_of(hash_res) {
        return err(failed(Why.Unavailable, "failed to hash password: " + e));
    }

    let make_id = s.new_id;
    let none_str: opt[str] = none;
    let acc = domain.Account {
        id: make_id(),
        username: some(username),
        email: some(email),
        phone_number: phone_number,
        password_hash: some(pass_hash),
        auth_provider: "LOCAL",
        status: "ACTIVE",
        kind: "USER",
        beneficial_owner_group: none_str,
        email_verified_at: none_str,
        verified_at: none_str,
        age_confirmed_at: none_str,
        created_at: ""
    };

    let insert = s.store.insert;
    let ir = insert(s.store.context, acc);
    guard let _ok = ir else let e = err_of(ir) {
        return err(failed(Why.Unavailable, e));
    }

    let audit = s.store.record_signup_audit;
    let _ar = audit(s.store.context, tenant_id, acc.id, audit_meta);

    return ok(acc);
}

pub fn create[C](s: Accounts[C], tenant_id: str, email: opt[str], password_hash: opt[str], auth_provider: str) -> result[domain.Account, Failed] {
    let make_id = s.new_id;
    let none_str: opt[str] = none;
    let n = domain.Account {
        id: make_id(),
        username: none_str,
        email: email,
        phone_number: none_str,
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

pub fn verify_email[C](s: Accounts[C], tenant_id: str, email: str) -> result[domain.Account, Failed] {
    let vf = s.store.verify_email;
    let r = vf(s.store.context, tenant_id, email);
    guard let _ok = r else let e = err_of(r) {
        return err(failed(Why.Unavailable, e));
    }
    return get_by_email(s, tenant_id, email);
}

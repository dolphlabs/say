import "pg";
import "../domain" as domain;
import "../service" as service;

pub gc struct Store {
    memory: opt[Memory],
    postgres: opt[Postgres]
}

pub fn in_memory() -> service.AccountStore[Store] {
    let none_pg: opt[Postgres] = none;
    return wrap(Store { memory: some(new_memory()), postgres: none_pg });
}

pub fn on_postgres(pool: pg.Pool) -> service.AccountStore[Store] {
    let none_mem: opt[Memory] = none;
    return wrap(Store { memory: none_mem, postgres: some(new_postgres(pool)) });
}

fn wrap(s: Store) -> service.AccountStore[Store] {
    return service.AccountStore[Store] {
        context: s,
        insert: store_insert,
        find: store_find,
        find_by_username: store_find_by_username,
        find_by_email: store_find_by_email,
        find_by_phone: store_find_by_phone,
        list: store_list,
        record_signup_audit: store_record_signup_audit,
        verify_email: store_verify_email
    };
}

fn store_insert(s: Store, n: domain.Account) -> result[bool, str] {
    if let p = s.postgres { return pg_insert(p, n); }
    guard let m = s.memory else { return err("no store"); }
    return memory_insert(m, n);
}

fn store_find(s: Store, tenant_id: str, id: str) -> result[opt[domain.Account], str] {
    if let p = s.postgres { return pg_find(p, tenant_id, id); }
    guard let m = s.memory else { return err("no store"); }
    return memory_find(m, tenant_id, id);
}

fn store_find_by_username(s: Store, tenant_id: str, username: str) -> result[opt[domain.Account], str] {
    if let p = s.postgres { return pg_find_by_username(p, tenant_id, username); }
    guard let m = s.memory else { return err("no store"); }
    return memory_find_by_username(m, tenant_id, username);
}

fn store_find_by_email(s: Store, tenant_id: str, email: str) -> result[opt[domain.Account], str] {
    if let p = s.postgres { return pg_find_by_email(p, tenant_id, email); }
    guard let m = s.memory else { return err("no store"); }
    return memory_find_by_email(m, tenant_id, email);
}

fn store_find_by_phone(s: Store, tenant_id: str, phone: str) -> result[opt[domain.Account], str] {
    if let p = s.postgres { return pg_find_by_phone(p, tenant_id, phone); }
    guard let m = s.memory else { return err("no store"); }
    return memory_find_by_phone(m, tenant_id, phone);
}

fn store_list(s: Store, tenant_id: str, offset: int, limit: int) -> result[[domain.Account], str] {
    if let p = s.postgres { return pg_list(p, tenant_id, offset, limit); }
    guard let m = s.memory else { return err("no store"); }
    return memory_list(m, tenant_id, offset, limit);
}

fn store_record_signup_audit(s: Store, tenant_id: str, account_id: str, meta: service.AuditMeta) -> result[bool, str] {
    if let p = s.postgres { return pg_record_signup_audit(p, tenant_id, account_id, meta); }
    guard let m = s.memory else { return err("no store"); }
    return memory_record_signup_audit(m, tenant_id, account_id, meta);
}

fn store_verify_email(s: Store, tenant_id: str, email: str) -> result[bool, str] {
    if let p = s.postgres { return pg_verify_email(p, tenant_id, email); }
    guard let m = s.memory else { return err("no store"); }
    return memory_verify_email(m, tenant_id, email);
}

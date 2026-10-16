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
        find_by_email: store_find_by_email,
        list: store_list
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

fn store_find_by_email(s: Store, tenant_id: str, email: str) -> result[opt[domain.Account], str] {
    if let p = s.postgres { return pg_find_by_email(p, tenant_id, email); }
    guard let m = s.memory else { return err("no store"); }
    return memory_find_by_email(m, tenant_id, email);
}

fn store_list(s: Store, tenant_id: str, offset: int, limit: int) -> result[[domain.Account], str] {
    if let p = s.postgres { return pg_list(p, tenant_id, offset, limit); }
    guard let m = s.memory else { return err("no store"); }
    return memory_list(m, tenant_id, offset, limit);
}

import "../domain" as domain;
import "../service" as service;

pub gc struct Store {
    memory: Memory
}

pub fn in_memory() -> service.NoteStore[Store] {
    return service.NoteStore[Store] { context: Store { memory: new_memory() },
                                         insert: store_insert, find: store_find,
                                         list: store_list };
}

fn store_insert(s: Store, n: domain.Note) -> result[bool, str] {
    return memory_insert(s.memory, n);
}

fn store_find(s: Store, tenant_id: str, id: str) -> result[opt[domain.Note], str] {
    return memory_find(s.memory, tenant_id, id);
}

fn store_list(s: Store, tenant_id: str, offset: int, limit: int) -> result[[domain.Note], str] {
    return memory_list(s.memory, tenant_id, offset, limit);
}

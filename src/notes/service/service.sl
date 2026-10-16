import "../domain" as domain;

// The notes use cases. The tenant is an explicit argument to every one --
// resolved by the HTTP edge, never read from anywhere else -- so a call
// cannot reach another tenant's notes by forgetting a filter.

pub gc struct Notes[C] {
    store: NoteStore[C],
    // Makes a note's id; injected so tests get predictable ones.
    new_id: fn() -> str,
}

pub enum Why {
    Invalid,
    NotFound,
    Unavailable,
}

// Why a use case did not succeed. `problems` for Invalid; `detail` is the
// store's own error for Unavailable, for the log only.
pub gc struct Failed {
    why: Why,
    problems: [domain.Problem],
    detail: str,
}

pub fn new_notes[C](store: NoteStore[C], new_id: fn() -> str) -> Notes[C] {
    return Notes[C] { store: store, new_id: new_id };
}

fn failed(why: Why, detail: str) -> Failed {
    let none_yet: [domain.Problem] = [];
    return Failed { why: why, problems: none_yet, detail: detail };
}

pub fn create[C](s: Notes[C], tenant_id: str, title: str, body: str) -> result[domain.Note, Failed] {
    let p = domain.problems(title, body);
    if len(p) > 0 {
        return err(Failed { why: Why.Invalid, problems: p, detail: "" });
    }
    let make_id = s.new_id;
    let n = domain.Note { id: make_id(), tenant_id: tenant_id, title: title, body: body };
    let insert = s.store.insert;
    let r = insert(s.store.context, n);
    guard let _ok = r else let e = err_of(r) {
        return err(failed(Why.Unavailable, e));
    }
    return ok(n);
}

pub fn get[C](s: Notes[C], tenant_id: str, id: str) -> result[domain.Note, Failed] {
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

pub fn list[C](s: Notes[C], tenant_id: str, offset: int, limit: int) -> result[[domain.Note], Failed] {
    let all = s.store.list;
    let r = all(s.store.context, tenant_id, offset, limit);
    guard let rows = r else let e = err_of(r) {
        return err(failed(Why.Unavailable, e));
    }
    return ok(rows);
}

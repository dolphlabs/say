pub fn worker_lease_try(p: Postgres, key: int) -> result[opt[int], str] {
    return st_lease_try(p, key);
}

pub fn worker_lease_release(p: Postgres, id: int) {
    st_lease_release(p, id);
}

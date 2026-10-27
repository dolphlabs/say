import "pg";
import "time";
import "../service" as service;

pub gc struct Postgres {
    pool: pg.Pool,
    timeout: int
}

pub fn new_postgres(pool: pg.Pool, timeout_ns: int) -> Postgres {
    return Postgres { pool: pool, timeout: timeout_ns };
}

pub fn ownership_store(postgres: Postgres) -> service.OwnershipStore[Postgres] {
    return service.OwnershipStore[Postgres] {
        context: postgres,
        register_node: st_register_node,
        heartbeat: st_heartbeat,
        acquire: st_acquire,
        release: st_release
    };
}

pub fn deadline(postgres: Postgres) -> until {
    return until_of(time.mono() + postgres.timeout);
}

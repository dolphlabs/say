import "pg";
import "time";
import "strings";
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
        candidates: st_candidates,
        register_node: st_register_node,
        heartbeat: st_heartbeat,
        acquire: st_acquire,
        mark_ready: st_mark_ready,
        release: st_release
    };
}

pub fn command_queue(postgres: Postgres) -> service.CommandQueue[Postgres] {
    return service.CommandQueue[Postgres] {
        context: postgres,
        enqueue_control: st_enqueue_control,
        enqueue_cancel: st_enqueue_cancel,
        enqueue_cancel_owned: st_enqueue_cancel_owned,
        load_pending: st_load_pending,
        sync_lifecycle: st_sync_lifecycle
    };
}

pub fn actor_writer(postgres: Postgres) -> service.ActorWriter[Postgres] {
    return service.ActorWriter[Postgres] {
        context: postgres,
        commit: st_commit
    };
}

pub fn order_admission_store(postgres: Postgres) -> service.OrderAdmissionStore[Postgres] {
    return service.OrderAdmissionStore[Postgres] {
        context: postgres,
        lookup: st_lookup_admission,
        admit: st_admit_order
    };
}

pub fn read_store(postgres: Postgres) -> service.ReadStore[Postgres] {
    return service.ReadStore[Postgres] {
        context:postgres,order:st_read_order,orders:st_read_orders,
        trades:st_read_trades,history:st_read_history
    };
}

pub fn book_view_store(postgres: Postgres) -> service.BookViewStore[Postgres] {
    return service.BookViewStore[Postgres] { context:postgres,ready_views:st_ready_views };
}

pub fn recovery_store(postgres: Postgres) -> service.RecoveryStore[Postgres] {
    return service.RecoveryStore[Postgres] {
        context: postgres,
        load: st_load_recovery,
        save_snapshot: st_save_snapshot,
        reconcile_projection: st_reconcile_projection,
        verify_epoch: st_verify_epoch,
        quarantine: st_quarantine
    };
}

pub fn deadline(postgres: Postgres) -> until {
    return until_of(time.mono() + postgres.timeout);
}

fn runtime_failure(error: str) -> str {
    if strings.contains(error,"SAY_QUEUE_FULL") { return "QUEUE_FULL"; }
    return error;
}

import "json";
import "pg";
import "zokor";
import "../domain" as core;
import "../service" as service;

gc struct LifecycleArg { postgres: Postgres, market_id: str }
gc struct LifecycleRow { status: str, mode: str, version: int, expired: bool, command_ref: str }
gc struct PendingCountRow { pending: int }

fn st_sync_lifecycle(postgres: Postgres,market_id: str) -> result[int,str] {
    return zokor.transaction(postgres.pool,LifecycleArg { postgres:postgres,market_id:market_id },
        sync_lifecycle_tx,deadline(postgres));
}

fn sync_lifecycle_tx(conn: pg.Conn,arg: LifecycleArg) -> result[int,str] {
    let season=pg.query(conn,
        "select s.id from seasons s join markets m on m.season_id=s.id where m.id=$1::uuid for share of s",
        [pg.arg_text(arg.market_id)],deadline(arg.postgres));
    guard let _season=season else let e=err_of(season) { return err(e); }
    let facts:result[[LifecycleRow],str]=zokor.conn_query_all(conn,
        "select m.status,m.book_mode as mode,m.version,"+
        "(s.status<>'ACTIVE' or s.ends_at<=clock_timestamp() or m.close_at<=clock_timestamp()) as expired,"+
        "gen_random_uuid()::text as command_ref from markets m join seasons s on s.id=m.season_id "+
        "where m.id=$1::uuid for no key update of m",[pg.arg_text(arg.market_id)],deadline(arg.postgres));
    guard let rows=facts else let e=err_of(facts) { return err(e); }
    if len(rows)!=1 { return err("MARKET_NOT_FOUND"); }
    let fact=rows[0];
    let kind="";
    if fact.mode!="CLOSED" {
        if fact.expired || (fact.status!="OPEN" && fact.status!="SUSPENDED") { kind="Close"; }
        else if fact.status=="SUSPENDED" && fact.mode!="SUSPENDED" { kind="Suspend"; }
        else if fact.status=="OPEN" && fact.mode=="SUSPENDED" { kind="Resume"; }
    }
    if kind!="" {
        let command=core.Command {
            kind:kind,seq:0,ref:fact.command_ref,order:core.empty_order(),order_id:"",
            account_id:"",system:true,reason:"REGISTRY_LIFECYCLE"
        };
        let enqueued=enqueue_tx(conn,CommandWriteArg { postgres:arg.postgres,command:service.EnqueueCommand {
            market_id:arg.market_id,command_ref:fact.command_ref,command_type:kind,order_id:"",
            source_key:"lifecycle:"+kind+":"+to_str(fact.version),payload:json.encode(command),bucket_start:0
        } });
        guard let _enqueued=enqueued else let e=err_of(enqueued) { return err(e); }
    }
    let counts:result[[PendingCountRow],str]=zokor.conn_query_all(conn,
        "select count(*)::bigint as pending from market_commands where market_id=$1::uuid and state='PENDING'",
        [pg.arg_text(arg.market_id)],deadline(arg.postgres));
    guard let count=counts else let e=err_of(counts) { return err(e); }
    return ok(count[0].pending);
}

gc struct PendingArg {
    postgres: Postgres,
    market_id: str,
    after_command_id: int,
    limit: int
}

gc struct CommandWriteArg {
    postgres: Postgres,
    command: service.EnqueueCommand
}

gc struct CancelWriteArg {
    postgres: Postgres,
    market_id: str,
    order_id: str,
    account_id: str,
    command_ref: str,
    source_key: str,
    payload: str
}

gc struct CancelOwnedArg {
    postgres: Postgres,
    order_id: str,
    account_id: str,
    command_ref: str
}

gc struct CancelAllArg {
    postgres: Postgres,
    market_id: str,
    account_id: str,
    command_ref: str
}


gc struct CancelMarketRow { market_id: str }

gc struct CancelOrderRow {
    status: str
}

gc struct PendingCancelRow {
    command_ref: str,
    queue_bucket: int
}

gc struct ReservationRow {
    command_ref: str,
    queue_bucket: int,
    existing: bool
}

gc struct FrontierRow {
    frontier: int
}

gc struct CommandRow {
    command_ref: str,
    command_id: int,
    command_type: str,
    order_id: str,
    source_key: str,
    queue_bucket: int,
    payload: str
}

fn st_load_pending(postgres: Postgres, market_id: str, after_command_id: int, limit: int) -> result[service.CommandBatch, str] {
    return zokor.transaction(postgres.pool,
        PendingArg {
            postgres: postgres,
            market_id: market_id,
            after_command_id: after_command_id,
            limit: limit
        },
        load_pending_tx, deadline(postgres));
}

fn st_enqueue_control(postgres: Postgres, command: service.EnqueueCommand) -> result[service.EnqueueResult, str] {
    return zokor.transaction(postgres.pool,
        CommandWriteArg { postgres: postgres, command: command },
        enqueue_tx, deadline(postgres));
}

fn st_enqueue_cancel(postgres: Postgres, market_id: str, order_id: str, account_id: str,
                     command_ref: str, source_key: str, payload: str) -> result[service.EnqueueResult, str] {
    return zokor.transaction(postgres.pool,
        CancelWriteArg { postgres:postgres,market_id:market_id,order_id:order_id,account_id:account_id,
            command_ref:command_ref,source_key:source_key,payload:payload },
        enqueue_cancel_tx,deadline(postgres));
}

fn st_enqueue_cancel_owned(postgres: Postgres, order_id: str, account_id: str,
                           command_ref: str) -> result[service.EnqueueResult,str] {
    let enqueued=zokor.transaction(postgres.pool,
        CancelOwnedArg { postgres:postgres,order_id:order_id,account_id:account_id,command_ref:command_ref },
        enqueue_cancel_owned_tx,deadline(postgres));
    guard let receipt=enqueued else let e=err_of(enqueued) { return err(runtime_failure(e)); }
    return ok(receipt);
}

fn enqueue_cancel_owned_tx(conn: pg.Conn,arg: CancelOwnedArg) -> result[service.EnqueueResult,str] {
    let order:result[[CancelMarketRow],str]=zokor.conn_query_all(conn,
        "select market_id::text as market_id from orders where id=$1::uuid and account_id=$2::uuid",
        [pg.arg_text(arg.order_id),pg.arg_text(arg.account_id)],deadline(arg.postgres));
    guard let rows=order else let e=err_of(order) { return err(e); }
    if len(rows)!=1 { return err("ORDER_NOT_FOUND"); }
    let command=core.Command {
        kind:"Cancel",seq:0,ref:arg.command_ref,order:core.empty_order(),order_id:arg.order_id,
        account_id:arg.account_id,system:false,reason:"USER_CANCEL"
    };
    return enqueue_cancel_tx(conn,CancelWriteArg {
        postgres:arg.postgres,market_id:rows[0].market_id,order_id:arg.order_id,
        account_id:arg.account_id,command_ref:arg.command_ref,
        source_key:"cancel:"+arg.account_id+":"+arg.order_id,payload:json.encode(command)
    });
}

fn st_enqueue_cancel_all(postgres: Postgres, market_id: str, account_id: str,
                         command_ref: str) -> result[service.EnqueueResult, str] {
    let enqueued = zokor.transaction(postgres.pool,
        CancelAllArg { postgres: postgres, market_id: market_id, account_id: account_id, command_ref: command_ref },
        enqueue_cancel_all_tx, deadline(postgres));
    guard let receipt = enqueued else let e = err_of(enqueued) { return err(runtime_failure(e)); }
    return ok(receipt);
}

fn enqueue_cancel_all_tx(conn: pg.Conn, arg: CancelAllArg) -> result[service.EnqueueResult, str] {
    let command = core.Command {
        kind: "CancelAll", seq: 0, ref: arg.command_ref, order: core.empty_order(), order_id: "",
        account_id: arg.account_id, system: false, reason: "USER_CANCEL"
    };
    let source_key = "cancel_all:" + arg.market_id + ":" + arg.account_id + ":" + arg.command_ref;
    let reserved: result[[ReservationRow], str] = zokor.conn_query_all(conn,
        "select command_ref::text as command_ref,bucket::integer as queue_bucket,existing " +
        "from say_runtime_reserve($1::uuid,$2::uuid,'CancelAll',$3,0)",
        [pg.arg_text(arg.market_id), pg.arg_text(arg.command_ref), pg.arg_text(source_key)], deadline(arg.postgres));
    guard let reservations = reserved else let e = err_of(reserved) { return err(e); }
    if len(reservations) != 1 { return err("RUNTIME_RESERVATION_EMPTY"); }
    let reservation = reservations[0];
    if reservation.existing {
        return ok(service.EnqueueResult {
            command_ref: reservation.command_ref, queue_bucket: reservation.queue_bucket, existing: true
        });
    }
    let inserted = pg.query(conn,
        "select say_runtime_enqueue($1::uuid,$2::uuid,'CancelAll',null,$3,$4::jsonb)",
        [pg.arg_text(arg.market_id), pg.arg_text(arg.command_ref),
         pg.arg_text(source_key), pg.arg_text(json.encode(command))], deadline(arg.postgres));
    guard let _inserted = inserted else let e = err_of(inserted) { return err(e); }
    return ok(service.EnqueueResult {
        command_ref: reservation.command_ref, queue_bucket: reservation.queue_bucket, existing: false
    });
}


fn enqueue_cancel_tx(conn: pg.Conn, arg: CancelWriteArg) -> result[service.EnqueueResult,str] {
    let order: result[[CancelOrderRow],str]=zokor.conn_query_all(conn,
        "select status from orders where id=$1::uuid and market_id=$2::uuid and account_id=$3::uuid",
        [pg.arg_text(arg.order_id),pg.arg_text(arg.market_id),pg.arg_text(arg.account_id)],deadline(arg.postgres));
    guard let order_rows=order else let e=err_of(order) { return err(e); }
    if len(order_rows)!=1 { return err("ORDER_NOT_FOUND"); }
    let pending: result[[PendingCancelRow],str]=zokor.conn_query_all(conn,
        "select id::text as command_ref,queue_bucket::integer as queue_bucket from market_commands " +
        "where order_id=$1::uuid and command_type='Cancel' order by command_id limit 1",
        [pg.arg_text(arg.order_id)],deadline(arg.postgres));
    guard let pending_rows=pending else let e=err_of(pending) { return err(e); }
    if len(pending_rows)>0 {
        return ok(service.EnqueueResult {
            command_ref:pending_rows[0].command_ref,queue_bucket:pending_rows[0].queue_bucket,existing:true
        });
    }
    if order_rows[0].status!="ADMITTED" && order_rows[0].status!="OPEN" && order_rows[0].status!="PARTIAL" {
        return err("ORDER_NOT_OPEN");
    }
    let reserved: result[[ReservationRow],str]=zokor.conn_query_all(conn,
        "select command_ref::text as command_ref,bucket::integer as queue_bucket,existing " +
        "from say_runtime_reserve($1::uuid,$2::uuid,'Cancel',$3,0)",
        [pg.arg_text(arg.market_id),pg.arg_text(arg.command_ref),pg.arg_text(arg.source_key)],deadline(arg.postgres));
    guard let reservations=reserved else let e=err_of(reserved) { return err(e); }
    if len(reservations)!=1 { return err("RUNTIME_RESERVATION_EMPTY"); }
    let reservation=reservations[0];
    if reservation.existing {
        return ok(service.EnqueueResult {
            command_ref:reservation.command_ref,queue_bucket:reservation.queue_bucket,existing:true
        });
    }
    let inserted=pg.query(conn,
        "select say_runtime_enqueue($1::uuid,$2::uuid,'Cancel',$3::uuid,$4,$5::jsonb)",
        [pg.arg_text(arg.market_id),pg.arg_text(arg.command_ref),pg.arg_text(arg.order_id),
         pg.arg_text(arg.source_key),pg.arg_text(arg.payload)],deadline(arg.postgres));
    guard let _inserted=inserted else let e=err_of(inserted) { return err(e); }
    return ok(service.EnqueueResult {
        command_ref:reservation.command_ref,queue_bucket:reservation.queue_bucket,existing:false
    });
}

fn enqueue_tx(conn: pg.Conn, arg: CommandWriteArg) -> result[service.EnqueueResult, str] {
    let command = arg.command;
    let reserved_result: result[[ReservationRow], str] = zokor.conn_query_all(conn,
        "select command_ref::text as command_ref,bucket::integer as queue_bucket,existing " +
        "from say_runtime_reserve($1::uuid,$2::uuid,$3,$4,$5)",
        [
            pg.arg_text(command.market_id),
            pg.arg_text(command.command_ref),
            pg.arg_text(command.command_type),
            pg.arg_text(command.source_key),
            pg.arg_int(command.bucket_start)
        ], deadline(arg.postgres));
    guard let reserved_rows = reserved_result else let e = err_of(reserved_result) { return err(e); }
    if len(reserved_rows) == 0 { return err("RUNTIME_RESERVATION_EMPTY"); }
    let reservation = reserved_rows[0];
    if reservation.existing {
        return ok(service.EnqueueResult {
            command_ref: reservation.command_ref,
            queue_bucket: reservation.queue_bucket,
            existing: true
        });
    }

    let inserted = pg.query(conn,
        "select say_runtime_enqueue($1::uuid,$2::uuid,$3,nullif($4,'')::uuid,$5,$6::jsonb)",
        [
            pg.arg_text(command.market_id),
            pg.arg_text(command.command_ref),
            pg.arg_text(command.command_type),
            pg.arg_text(command.order_id),
            pg.arg_text(command.source_key),
            pg.arg_text(command.payload)
        ], deadline(arg.postgres));
    guard let _rows = inserted else let e = err_of(inserted) { return err(e); }
    return ok(service.EnqueueResult {
        command_ref: reservation.command_ref,
        queue_bucket: reservation.queue_bucket,
        existing: false
    });
}

fn load_pending_tx(conn: pg.Conn, arg: PendingArg) -> result[service.CommandBatch, str] {
    let locked = pg.query(conn,
        "select pg_advisory_xact_lock(73101,hashtext($1::uuid::text))",
        [pg.arg_text(arg.market_id)], deadline(arg.postgres));
    guard let _lock = locked else let e = err_of(locked) { return err(e); }

    let frontier_result: result[[FrontierRow], str] = zokor.conn_query_all(conn,
        "select coalesce(max(command_id),0)::bigint as frontier from market_commands where market_id=$1::uuid",
        [pg.arg_text(arg.market_id)], deadline(arg.postgres));
    guard let frontier_rows = frontier_result else let e = err_of(frontier_result) { return err(e); }
    let frontier = frontier_rows[0].frontier;

    let command_result: result[[CommandRow], str] = zokor.conn_query_all(conn,
        "select id::text as command_ref,command_id::bigint as command_id,command_type," +
        "coalesce(order_id::text,'') as order_id,coalesce(source_key,'') as source_key," +
        "queue_bucket::integer as queue_bucket,payload::text as payload " +
        "from market_commands where market_id=$1::uuid and state='PENDING' " +
        "and command_id>$2 and command_id<=$3 order by command_id limit $4",
        [
            pg.arg_text(arg.market_id),
            pg.arg_int(arg.after_command_id),
            pg.arg_int(frontier),
            pg.arg_int(arg.limit)
        ], deadline(arg.postgres));
    guard let commands = command_result else let e = err_of(command_result) { return err(e); }
    let result_commands: [service.QueuedCommand] = [];
    for command in commands {
        push(result_commands, service.QueuedCommand {
            command_ref: command.command_ref,
            command_id: command.command_id,
            command_type: command.command_type,
            order_id: command.order_id,
            source_key: command.source_key,
            queue_bucket: command.queue_bucket,
            payload: command.payload
        });
    }
    return ok(service.CommandBatch { frontier: frontier, commands: result_commands });
}

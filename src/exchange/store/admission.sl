import "json";
import "pg";
import "zokor";
import "../domain" as core;
import "../../ledger/store" as ledger_store;
import "../service" as service;

gc struct AdmissionArg {
    postgres: Postgres,
    request: service.AdmissionRequest
}

gc struct IdempotencyRow {
    request_hash: str,
    order_id: str,
    status: str,
    command_ref: str
}

gc struct MarketSeasonRow {
    season_id: str
}

gc struct SeasonAdmissionRow {
    status: str,
    active: bool
}

gc struct AccountAdmissionRow {
    status: str,
    kind: str
}

gc struct HaltAdmissionRow {
    halted: bool
}

gc struct MarketAdmissionRow {
    status: str,
    close_open: bool,
    runtime_status: str,
    owner_epoch: int,
    verified_epoch: int,
    owner_live: bool,
    node_live: bool,
    min_price: int,
    max_price: int,
    tick: int,
    fee_units: int,
    max_order_qty: int,
    min_order_notional: int
}

gc struct QueueClaimRow {
    command_ref: str,
    bucket: int,
    existing: bool
}

fn st_admit_order(postgres: Postgres, request: service.AdmissionRequest) -> result[service.AdmissionReceipt, str] {
    let admitted=zokor.transaction(postgres.pool,
        AdmissionArg { postgres:postgres,request:request },admit_order_tx,deadline(postgres));
    guard let receipt=admitted else let e=err_of(admitted) { return err(runtime_failure(e)); }
    return ok(receipt);
}

fn st_lookup_admission(postgres: Postgres, account_id: str, idem_key: str,
                       intent_hash: str) -> result[opt[service.AdmissionReceipt],str] {
    let rows:result[[IdempotencyRow],str]=zokor.query_all(postgres.pool,
        "select i.request_hash,coalesce(i.order_id::text,'') as order_id,coalesce(o.status,'') as status,"+
        "coalesce(c.id::text,'') as command_ref from idempotency_records i "+
        "left join orders o on o.id=i.order_id "+
        "left join market_commands c on c.market_id=o.market_id and c.source_key='order:'||i.account_id::text||':'||i.idem_key "+
        "where i.account_id=$1::uuid and i.scope='order' and i.idem_key=$2",
        [pg.arg_text(account_id),pg.arg_text(idem_key)],deadline(postgres));
    guard let found=rows else let e=err_of(rows) { return err(e); }
    if len(found)==0 {
        let empty:opt[service.AdmissionReceipt]=none;
        return ok(empty);
    }
    let old=found[0];
    if old.request_hash!=intent_hash { return err("IDEMPOTENCY_CONFLICT"); }
    if old.order_id=="" || old.status=="" || old.command_ref=="" { return err("IDEMPOTENCY_INCOMPLETE"); }
    return ok(some(service.AdmissionReceipt {
        order_id:old.order_id,command_ref:old.command_ref,status:old.status,existing:true
    }));
}

fn admit_order_tx(conn: pg.Conn, arg: AdmissionArg) -> result[service.AdmissionReceipt, str] {
    let request=arg.request;
    let idem_lock=pg.query(conn,
        "select pg_advisory_xact_lock(73103,hashtext($1||':order:'||$2))",
        [pg.arg_text(request.account_id),pg.arg_text(request.idem_key)],deadline(arg.postgres));
    guard let _idem_lock=idem_lock else let e=err_of(idem_lock) { return err(e); }

    let existing: result[[IdempotencyRow],str]=zokor.conn_query_all(conn,
        "select i.request_hash,coalesce(i.order_id::text,'') as order_id,coalesce(o.status,'') as status," +
        "coalesce(c.id::text,'') as command_ref " +
        "from idempotency_records i left join orders o on o.id=i.order_id " +
        "left join market_commands c on c.market_id=o.market_id and c.source_key='order:'||i.account_id::text||':'||i.idem_key " +
        "where i.account_id=$1::uuid and i.scope='order' and i.idem_key=$2",
        [pg.arg_text(request.account_id),pg.arg_text(request.idem_key)],deadline(arg.postgres));
    guard let old_rows=existing else let e=err_of(existing) { return err(e); }
    if len(old_rows)>0 {
        let old=old_rows[0];
        if old.request_hash!=request.intent_hash { return err("IDEMPOTENCY_CONFLICT"); }
        if old.order_id=="" || old.status=="" || old.command_ref=="" { return err("IDEMPOTENCY_INCOMPLETE"); }
        return ok(service.AdmissionReceipt {
            order_id:old.order_id,command_ref:old.command_ref,status:old.status,existing:true
        });
    }

    let market_season: result[[MarketSeasonRow],str]=zokor.conn_query_all(conn,
        "select season_id::text as season_id from markets where id=$1::uuid",
        [pg.arg_text(request.market_id)],deadline(arg.postgres));
    guard let season_rows=market_season else let e=err_of(market_season) { return err(e); }
    if len(season_rows)!=1 { return err("MARKET_NOT_FOUND"); }
    let season_id=season_rows[0].season_id;
    let season_lock: result[[SeasonAdmissionRow],str]=zokor.conn_query_all(conn,
        "select status,ends_at>clock_timestamp() as active from seasons where id=$1::uuid for share",
        [pg.arg_text(season_id)],deadline(arg.postgres));
    guard let seasons=season_lock else let e=err_of(season_lock) { return err(e); }
    if len(seasons)!=1 || seasons[0].status!="ACTIVE" || !seasons[0].active {
        return err("SEASON_NOT_ACTIVE");
    }
    let no_args: [pg.Arg]=[];
    let halt_lock: result[[HaltAdmissionRow],str]=zokor.conn_query_all(conn,
        "select halted from trading_halt where id=1 for share",no_args,deadline(arg.postgres));
    guard let halt_rows=halt_lock else let e=err_of(halt_lock) { return err(e); }
    if len(halt_rows)!=1 || halt_rows[0].halted { return err("TRADING_HALTED"); }
    let account: result[[AccountAdmissionRow],str]=zokor.conn_query_all(conn,
        "select status,lower(kind) as kind from accounts where id=$1::uuid",
        [pg.arg_text(request.account_id)],deadline(arg.postgres));
    guard let accounts=account else let e=err_of(account) { return err(e); }
    if len(accounts)!=1 || accounts[0].status!="ACTIVE" || accounts[0].kind!=request.order.owner_kind {
        return err("ACCOUNT_DISABLED");
    }
    let market: result[[MarketAdmissionRow],str]=zokor.conn_query_all(conn,
        "select m.status,m.close_at>clock_timestamp() as close_open,m.runtime_status,m.owner_epoch," +
        "m.runtime_verified_epoch as verified_epoch," +
        "o.lease_until>clock_timestamp() as owner_live,n.live_until>clock_timestamp() as node_live," +
        "m.min_price,m.max_price,m.tick,m.fee_units,m.max_order_qty,m.min_order_notional " +
        "from markets m join market_owners o on o.market_id=m.id and o.epoch=m.owner_epoch " +
        "join runtime_nodes n on n.id=o.node_id where m.id=$1::uuid",
        [pg.arg_text(request.market_id)],deadline(arg.postgres));
    guard let market_rows=market else let e=err_of(market) { return err(e); }
    if len(market_rows)!=1 { return err("MARKET_DEGRADED"); }
    let facts=market_rows[0];
    if facts.status=="SUSPENDED" { return err("MARKET_SUSPENDED"); }
    if facts.status!="OPEN" || !facts.close_open { return err("MARKET_NOT_OPEN"); }
    if facts.runtime_status!="READY" || facts.owner_epoch!=facts.verified_epoch ||
       !facts.owner_live || !facts.node_live { return err("MARKET_DEGRADED"); }
    let order=request.order;
    if order.limit<facts.min_price || order.limit>facts.max_price || facts.tick<1 || facts.fee_units!=1 ||
       order.limit%facts.tick!=0 || order.qty>facts.max_order_qty {
        return err("INVALID_ORDER");
    }
    guard let notional=core.mul_units(order.limit,order.qty) else { return err("INVALID_ORDER"); }
    if notional<facts.min_order_notional { return err("INVALID_ORDER"); }
    let expected_sedi=1;
    if order.side=="BUY" {
        guard let with_fee=core.add_units(notional,1) else { return err("INVALID_ORDER"); }
        expected_sedi=with_fee;
    }
    if order.sedi_original!=expected_sedi ||
       (order.side=="BUY" && order.shares_original!=0) ||
       (order.side=="SELL" && order.shares_original!=order.qty) {
        return err("INVALID_ORDER");
    }

    let claim=pg.query(conn,
        "insert into idempotency_records(account_id,scope,idem_key,request_hash,state) " +
        "values($1::uuid,'order',$2,$3,'PENDING')",
        [pg.arg_text(request.account_id),pg.arg_text(request.idem_key),pg.arg_text(request.intent_hash)],deadline(arg.postgres));
    guard let _claim=claim else let e=err_of(claim) { return err(e); }

    let reservation: result[[QueueClaimRow],str]=zokor.conn_query_all(conn,
        "select command_ref::text as command_ref,bucket::integer as bucket,existing " +
        "from say_runtime_reserve($1::uuid,$2::uuid,'Place',$3,$4)",
        [pg.arg_text(request.market_id),pg.arg_text(request.command_ref),pg.arg_text(request.source_key),
         pg.arg_int(request.bucket_start)],deadline(arg.postgres));
    guard let claims=reservation else let e=err_of(reservation) { return err(e); }
    if len(claims)!=1 || claims[0].existing { return err("QUEUE_COMMAND_ALREADY_EXISTS"); }

    let holds=ledger_store.reserve_order_holds(conn,request.order.owner_kind,request.account_id,season_id,
        request.market_id,request.order_id,request.order.outcome,request.order.sedi_original,
        request.order.shares_original,deadline(arg.postgres));
    guard let hold_ids=holds else let e=err_of(holds) { return err(e); }
    order.sedi_hold_id=hold_ids.sedi_hold_id;
    order.share_hold_id=hold_ids.share_hold_id;

    let inserted=pg.query(conn,
        "insert into orders(id,account_id,market_id,outcome,side,limit_price,original_qty,remaining_qty,status,tif," +
        "fee_posted,accepted_seq,season_id,owner_kind,owner_group,sedi_hold_id,share_hold_id,sedi_original," +
        "shares_original,original_intent) " +
        "values($1::uuid,$2::uuid,$3::uuid,$4,$5,$6,$7,$7,'ADMITTED',$8,false,null,$9::uuid,$10," +
        "nullif($11,'')::uuid,$12::uuid,nullif($13,'')::uuid,$14,$15,$16::jsonb)",
        [pg.arg_text(request.order_id),pg.arg_text(request.account_id),pg.arg_text(request.market_id),
         pg.arg_text(order.outcome),pg.arg_text(order.side),pg.arg_int(order.limit),pg.arg_int(order.qty),
         pg.arg_text(order.tif),pg.arg_text(season_id),pg.arg_text(order.owner_kind),pg.arg_text(order.owner_group),
         pg.arg_text(order.sedi_hold_id),pg.arg_text(order.share_hold_id),pg.arg_int(order.sedi_original),
         pg.arg_int(order.shares_original),pg.arg_text(request.original_intent)],deadline(arg.postgres));
    guard let _inserted=inserted else let e=err_of(inserted) { return err(e); }

    let command=core.Command {
        kind:"Place",seq:0,ref:request.command_ref,order:order,order_id:"",
        account_id:request.account_id,system:false,reason:""
    };
    let queued=pg.query(conn,
        "select say_runtime_enqueue($1::uuid,$2::uuid,'Place',$3::uuid,$4,$5::jsonb)",
        [pg.arg_text(request.market_id),pg.arg_text(request.command_ref),pg.arg_text(request.order_id),
         pg.arg_text(request.source_key),pg.arg_text(json.encode(command))],deadline(arg.postgres));
    guard let _queued=queued else let e=err_of(queued) { return err(e); }
    let linked=pg.query(conn,
        "update idempotency_records set order_id=$3::uuid where account_id=$1::uuid and scope='order' and idem_key=$2",
        [pg.arg_text(request.account_id),pg.arg_text(request.idem_key),pg.arg_text(request.order_id)],deadline(arg.postgres));
    guard let _linked=linked else let e=err_of(linked) { return err(e); }
    return ok(service.AdmissionReceipt {
        order_id:request.order_id,command_ref:request.command_ref,status:"ADMITTED",existing:false
    });
}

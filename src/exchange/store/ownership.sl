import "builder";
import "pg";
import "time";
import "zokor";
import "../service" as service;

gc struct NodeArg {
    postgres: Postgres,
    node_id: str,
    name: str,
    live_seconds: int
}

gc struct HeartbeatArg {
    postgres: Postgres,
    node_id: str,
    live_seconds: int,
    market_ids: str,
    epochs: str
}

gc struct HeartbeatRow {
    node_live: bool,
    market_id: str,
    renewed: bool
}

gc struct MarketRow {
    owner_epoch: int
}

gc struct NodeRow {
    id: str
}

gc struct OwnerRow {
    node_id: str,
    epoch: int,
    active: bool
}

gc struct CandidateRow { id: str }
gc struct ReadyRow { id: str }

gc struct ClaimArg {
    postgres: Postgres,
    market_id: str,
    node_id: str,
    lease_seconds: int
}

gc struct ReleaseArg {
    postgres: Postgres,
    market_id: str,
    node_id: str,
    epoch: int
}

fn st_candidates(postgres: Postgres, after_id: str, limit: int) -> result[[str], str] {
    let rows: result[[CandidateRow], str] = zokor.query_all(postgres.pool,
        "select m.id::text as id from markets m where ($1='' or m.id>$1::uuid) " +
        "and m.status in ('OPEN','SUSPENDED','CLOSED','RESOLUTION_PENDING','DISPUTED','RESOLVED','VOIDED','SETTLING','SETTLED') " +
        "and m.runtime_status<>'DEGRADED' and (" +
        "m.runtime_status<>'READY' or not exists(select 1 from market_owners o join runtime_nodes n on n.id=o.node_id " +
        "where o.market_id=m.id and o.epoch=m.owner_epoch and o.lease_until>clock_timestamp() " +
        "and n.live_until>clock_timestamp() and not n.draining) or exists " +
        "(select 1 from market_commands c where c.market_id=m.id and c.state='PENDING') or " +
        "(m.status<>'OPEN' and exists(select 1 from orders o where o.market_id=m.id and o.remaining_qty>0 " +
        "and o.status in ('OPEN','PARTIAL','ADMITTED')))) order by m.id limit $2",
        [pg.arg_text(after_id),pg.arg_int(limit)],deadline(postgres));
    guard let candidates=rows else let e=err_of(rows) { return err(e); }
    let ids:[str]=[];
    for candidate in candidates { push(ids,candidate.id); }
    return ok(ids);
}

fn st_mark_ready(postgres: Postgres, market_id: str, node_id: str, epoch: int) -> result[bool, str] {
    let rows: result[[ReadyRow], str] = zokor.query_all(postgres.pool,
        "update markets m set runtime_status='READY',runtime_reason=null,runtime_verified_epoch=$3," +
        "runtime_changed_at=clock_timestamp() from market_owners o,runtime_nodes n " +
        "where m.id=$1::uuid and o.market_id=m.id and o.node_id=$2::uuid and o.epoch=$3 " +
        "and o.lease_until>clock_timestamp() and n.id=o.node_id and n.live_until>clock_timestamp() " +
        "and m.owner_epoch=$3 and not exists(select 1 from market_commands c " +
        "where c.market_id=m.id and c.state='PENDING') returning m.id::text as id",
        [pg.arg_text(market_id),pg.arg_text(node_id),pg.arg_int(epoch)],deadline(postgres));
    guard let updated=rows else let e=err_of(rows) { return err(e); }
    return ok(len(updated)==1);
}

fn st_register_node(postgres: Postgres, node_id: str, name: str, live_seconds: int) -> result[bool, str] {
    let transaction_result = zokor.transaction(postgres.pool,
        NodeArg { postgres: postgres, node_id: node_id, name: name, live_seconds: live_seconds },
        register_node_tx, deadline(postgres));
    guard let registered = transaction_result else let e = err_of(transaction_result) { return err(e); }
    return ok(registered);
}

fn register_node_tx(conn: pg.Conn, arg: NodeArg) -> result[bool, str] {
    let query_result = pg.query(conn,
        "insert into runtime_nodes(id,name,heartbeat_at,live_until,draining) " +
        "values($1::uuid,$2,clock_timestamp(),clock_timestamp()+make_interval(secs=>$3::double precision),false)",
        [pg.arg_text(arg.node_id), pg.arg_text(arg.name), pg.arg_int(arg.live_seconds)],
        deadline(arg.postgres));
    guard let _rows = query_result else let e = err_of(query_result) { return err(e); }
    return ok(true);
}

fn st_heartbeat(postgres: Postgres, node_id: str, live_seconds: int, market_ids: [str], epochs: [int]) -> result[service.Heartbeat, str] {
    let transaction_result = zokor.transaction(postgres.pool,
        HeartbeatArg {
            postgres: postgres,
            node_id: node_id,
            live_seconds: live_seconds,
            market_ids: uuid_array(market_ids),
            epochs: int_array(epochs)
        },
        heartbeat_tx, deadline(postgres));
    guard let rows = transaction_result else let e = err_of(transaction_result) { return err(e); }
    if len(rows) == 0 { return err("RUNTIME_HEARTBEAT_EMPTY"); }
    let node_live = rows[0].node_live;
    let markets: [service.MarketLease] = [];
    for row in rows {
        if len(row.market_id) > 0 {
            push(markets, service.MarketLease { market_id: row.market_id, renewed: row.renewed });
        }
    }
    return ok(service.Heartbeat { node_live: node_live, markets: markets });
}

fn heartbeat_tx(conn: pg.Conn, arg: HeartbeatArg) -> result[[HeartbeatRow], str] {
    return zokor.conn_query_all(conn,
        "with active_node as (" +
        " update runtime_nodes set heartbeat_at=clock_timestamp(),live_until=clock_timestamp()+make_interval(secs=>$2::double precision)" +
        " where id=$1::uuid and live_until>clock_timestamp() and draining=false returning id" +
        "), expected as (" +
        " select * from unnest($3::uuid[],$4::bigint[]) as e(market_id,epoch)" +
        "), renewed as (" +
        " update market_owners o set renewed_at=clock_timestamp(),lease_until=clock_timestamp()+make_interval(secs=>$2::double precision)" +
        " from expected e,active_node n,markets m where o.market_id=e.market_id and o.node_id=n.id and o.epoch=e.epoch" +
        " and m.id=e.market_id and m.owner_epoch=e.epoch" +
        " and o.lease_until>clock_timestamp() returning o.market_id" +
        "), result_rows as (" +
        " select e.market_id,r.market_id is not null as renewed from expected e left join renewed r on r.market_id=e.market_id" +
        " union all select null::uuid,false where not exists(select 1 from expected)" +
        ")" +
        " select exists(select 1 from active_node) as node_live,coalesce(market_id::text,'') as market_id,renewed" +
        " from result_rows",
        [
            pg.arg_text(arg.node_id),
            pg.arg_int(arg.live_seconds),
            pg.arg_text(arg.market_ids),
            pg.arg_text(arg.epochs)
        ],
        deadline(arg.postgres));
}

fn st_acquire(postgres: Postgres, market_id: str, node_id: str, lease_seconds: int) -> result[service.Claim, str] {
    return zokor.transaction(postgres.pool,
        ClaimArg { postgres: postgres, market_id: market_id, node_id: node_id, lease_seconds: lease_seconds },
        acquire_tx, deadline(postgres));
}

fn acquire_tx(conn: pg.Conn, arg: ClaimArg) -> result[service.Claim, str] {
    let market_result: result[[MarketRow], str] = zokor.conn_query_all(conn,
        "select owner_epoch from markets where id=$1::uuid for no key update",
        [pg.arg_text(arg.market_id)], deadline(arg.postgres));
    guard let markets = market_result else let e = err_of(market_result) { return err(e); }
    if len(markets) == 0 { return err("MARKET_NOT_FOUND"); }
    let market_epoch = markets[0].owner_epoch;

    let node_result: result[[NodeRow], str] = zokor.conn_query_all(conn,
        "select id::text as id from runtime_nodes where id=$1::uuid and live_until>clock_timestamp() and draining=false for share",
        [pg.arg_text(arg.node_id)], deadline(arg.postgres));
    guard let nodes = node_result else let e = err_of(node_result) { return err(e); }
    if len(nodes) == 0 { return err("RUNTIME_NODE_NOT_LIVE"); }

    let owner_result: result[[OwnerRow], str] = zokor.conn_query_all(conn,
        "select o.node_id::text as node_id,o.epoch," +
        "(o.lease_until>clock_timestamp() and n.live_until>clock_timestamp() and not n.draining) as active " +
        "from market_owners o left join runtime_nodes n on n.id=o.node_id " +
        "where o.market_id=$1::uuid for update of o",
        [pg.arg_text(arg.market_id)], deadline(arg.postgres));
    guard let owners = owner_result else let e = err_of(owner_result) { return err(e); }
    if len(owners) > 0 {
        let current = owners[0];
        if current.active && current.epoch != market_epoch {
            return err("OWNER_EPOCH_MISMATCH");
        }
        if current.active && current.node_id != arg.node_id {
            return ok(service.Claim {
                market_id: arg.market_id,
                node_id: current.node_id,
                epoch: current.epoch,
                acquired: false,
                renewed: false
            });
        }
        if current.active && current.node_id == arg.node_id {
            let renewed = pg.query(conn,
                "update market_owners set renewed_at=clock_timestamp()," +
                "lease_until=clock_timestamp()+make_interval(secs=>$4::double precision) " +
                "where market_id=$1::uuid and node_id=$2::uuid and epoch=$3 and lease_until>clock_timestamp()",
                [
                    pg.arg_text(arg.market_id),
                    pg.arg_text(arg.node_id),
                    pg.arg_int(current.epoch),
                    pg.arg_int(arg.lease_seconds)
                ],
                deadline(arg.postgres));
            guard let _rows = renewed else let e = err_of(renewed) { return err(e); }
            return ok(service.Claim {
                market_id: arg.market_id,
                node_id: arg.node_id,
                epoch: current.epoch,
                acquired: false,
                renewed: true
            });
        }
    }

    let previous_epoch = market_epoch;
    if len(owners) > 0 && owners[0].epoch > previous_epoch {
        previous_epoch = owners[0].epoch;
    }
    if previous_epoch >= 9223372036854775807 { return err("OWNER_EPOCH_EXHAUSTED"); }
    let epoch = previous_epoch + 1;
    let market_update = pg.query(conn,
        "update markets set owner_epoch=$2,runtime_status='RECOVERING'," +
        "runtime_reason='OWNER_ACQUIRED',runtime_changed_at=clock_timestamp() where id=$1::uuid",
        [pg.arg_text(arg.market_id), pg.arg_int(epoch)], deadline(arg.postgres));
    guard let _updated = market_update else let e = err_of(market_update) { return err(e); }
    let owner_upsert = pg.query(conn,
        "insert into market_owners(market_id,node_id,epoch,lease_until,acquired_at,renewed_at) " +
        "values($1::uuid,$2::uuid,$3,clock_timestamp()+make_interval(secs=>$4::double precision),clock_timestamp(),clock_timestamp()) " +
        "on conflict(market_id) do update set node_id=excluded.node_id,epoch=excluded.epoch," +
        "lease_until=excluded.lease_until,acquired_at=excluded.acquired_at,renewed_at=excluded.renewed_at",
        [
            pg.arg_text(arg.market_id),
            pg.arg_text(arg.node_id),
            pg.arg_int(epoch),
            pg.arg_int(arg.lease_seconds)
        ],
        deadline(arg.postgres));
    guard let _owner = owner_upsert else let e = err_of(owner_upsert) { return err(e); }
    return ok(service.Claim {
        market_id: arg.market_id,
        node_id: arg.node_id,
        epoch: epoch,
        acquired: true,
        renewed: false
    });
}

fn st_release(postgres: Postgres, market_id: str, node_id: str, epoch: int) -> result[bool, str] {
    return zokor.transaction(postgres.pool,
        ReleaseArg { postgres: postgres, market_id: market_id, node_id: node_id, epoch: epoch },
        release_tx, deadline(postgres));
}

fn release_tx(conn: pg.Conn, arg: ReleaseArg) -> result[bool, str] {
    let market_result = pg.query(conn,
        "select id from markets where id=$1::uuid for no key update",
        [pg.arg_text(arg.market_id)], deadline(arg.postgres));
    guard let _market = market_result else let e = err_of(market_result) { return err(e); }
    let released_result: result[[NodeRow], str] = zokor.conn_query_all(conn,
        "update market_owners set lease_until=clock_timestamp(),renewed_at=clock_timestamp() " +
        "where market_id=$1::uuid and node_id=$2::uuid and epoch=$3 and lease_until>clock_timestamp() " +
        "returning node_id::text as id",
        [pg.arg_text(arg.market_id), pg.arg_text(arg.node_id), pg.arg_int(arg.epoch)],
        deadline(arg.postgres));
    guard let released = released_result else let e = err_of(released_result) { return err(e); }
    if len(released) == 0 { return ok(false); }
    let marked = pg.query(conn,
        "update markets set runtime_status='RECOVERING',runtime_reason='OWNER_RELEASED'," +
        "runtime_changed_at=clock_timestamp() where id=$1::uuid and runtime_status<>'DEGRADED'",
        [pg.arg_text(arg.market_id)], deadline(arg.postgres));
    guard let _rows = marked else let e = err_of(marked) { return err(e); }
    return ok(true);
}

fn uuid_array(values: [str]) -> str {
    let output = builder.new_str().write("{");
    for i in 0..len(values) {
        if i > 0 { output.write(","); }
        output.write("\"").write(values[i]).write("\"");
    }
    return output.write("}").finish();
}

fn int_array(values: [int]) -> str {
    let output = builder.new_str().write("{");
    for i in 0..len(values) {
        if i > 0 { output.write(","); }
        output.write_int(values[i]);
    }
    return output.write("}").finish();
}

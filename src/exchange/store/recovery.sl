import "pg";
import "zokor";
import "../domain" as core;
import "../service" as service;

gc struct RecoveryArg {
    postgres: Postgres,
    market_id: str
}

gc struct RecoveryMarketRow {
    season_id: str,
    V: int,
    min_price: int,
    max_price: int,
    tick: int,
    max_order_qty: int,
    min_order_notional: int,
    issued_pairs: int,
    committed_seq: int,
    rolling_hash: str,
    mode: str
}

gc struct RecoveryStepRow {
    seq: int,
    command_payload: str,
    transition_payload: str
}

gc struct RecoverySnapshotRow {
    committed_seq: int,
    state_hash: str,
    full_hash: str,
    schema_version: int,
    payload: str
}

gc struct SnapshotSavedRow { id: str }
gc struct RecoveryCheckRow { mismatches: int }
gc struct VerifiedEpochRow { book_seq: int, as_of: int, lease_until: int }
gc struct VerifyEpochArg { postgres: Postgres, snapshot: service.SnapshotWrite, pending: int, controls: int }

fn st_quarantine(postgres: Postgres,market: str,node: str,epoch: int,reason: str) -> result[bool,str] {
    let updated=pg.pool_query(postgres.pool,
        "update markets m set runtime_status='DEGRADED',runtime_reason=$4,runtime_changed_at=clock_timestamp() "+
        "from market_owners o where m.id=$1::uuid and m.owner_epoch=$3 and o.market_id=m.id "+
        "and o.node_id=$2::uuid and o.epoch=$3",
        [pg.arg_text(market),pg.arg_text(node),pg.arg_int(epoch),pg.arg_text(reason)],deadline(postgres));
    guard let _updated=updated else let e=err_of(updated) { return err(e); }
    return ok(true);
}

fn st_verify_epoch(postgres: Postgres,snapshot: service.SnapshotWrite,pending: int,controls: int) -> result[int,str] {
    return zokor.transaction(postgres.pool,
        VerifyEpochArg { postgres:postgres,snapshot:snapshot,pending:pending,controls:controls },
        verify_epoch_tx,deadline(postgres));
}

fn verify_epoch_tx(conn: pg.Conn,arg: VerifyEpochArg) -> result[int,str] {
    let snapshot=arg.snapshot;
    let rows:result[[VerifiedEpochRow],str]=zokor.conn_query_all(conn,
        "update markets m set runtime_verified_epoch=$3 from market_owners o,runtime_nodes n "+
        "where m.id=$1::uuid and m.owner_epoch=$3 and m.committed_seq=$4 and m.rolling_hash=$5 "+
        "and o.market_id=m.id and o.node_id=$2::uuid and o.epoch=$3 and o.lease_until>clock_timestamp() "+
        "and n.id=o.node_id and n.live_until>clock_timestamp() and not n.draining returning m.book_seq,"+
        "floor(extract(epoch from clock_timestamp())*1000)::bigint as as_of,"+
        "floor(extract(epoch from least(o.lease_until,n.live_until))*1000)::bigint as lease_until",
        [pg.arg_text(snapshot.market_id),pg.arg_text(snapshot.node_id),pg.arg_int(snapshot.owner_epoch),
         pg.arg_int(snapshot.committed_seq),pg.arg_text(snapshot.state_hash)],deadline(arg.postgres));
    guard let verified=rows else let e=err_of(rows) { return err(e); }
    if len(verified)!=1 { return err("RECOVERY_EPOCH_FENCED"); }
    let prepared=pg.query(conn,"select say_runtime_prepare_queue($1::uuid,$2,$3)",
        [pg.arg_text(snapshot.market_id),pg.arg_int(arg.pending),pg.arg_int(arg.controls)],deadline(arg.postgres));
    guard let _prepared=prepared else let e=err_of(prepared) { return err(e); }
    let decoded:result[core.Snapshot,str]=json.decode(snapshot.payload);
    guard let state=decoded else let e=err_of(decoded) { return err(e); }
    let capacity=len(state.orders);
    if capacity<1 { capacity=1; }
    let restored=core.restore(state,capacity);
    guard let book=restored else let e=err_of(restored) { return err(e); }
    let meta=verified[0];
    let view=service.book_view(&book,snapshot.owner_epoch,0,"RECOVERING",meta.as_of,meta.lease_until);
    view.book_seq=meta.book_seq;
    let saved=pg.query(conn,
        "insert into market_book_views(market_id,owner_epoch,committed_seq,book_seq,payload,changed_at) "+
        "values($1::uuid,$2,$3,$4,$5::jsonb,clock_timestamp()) on conflict(market_id) do update set "+
        "owner_epoch=excluded.owner_epoch,committed_seq=excluded.committed_seq,book_seq=excluded.book_seq,"+
        "payload=excluded.payload,changed_at=excluded.changed_at",
        [pg.arg_text(snapshot.market_id),pg.arg_int(snapshot.owner_epoch),pg.arg_int(snapshot.committed_seq),
         pg.arg_int(meta.book_seq),pg.arg_text(json.encode(view))],deadline(arg.postgres));
    guard let _saved=saved else let e=err_of(saved) { return err(e); }
    return ok(verified[0].book_seq);
}

fn st_reconcile_projection(postgres: Postgres, market_id: str, snapshot: core.Snapshot) -> result[bool,str] {
    let rows:result[[RecoveryCheckRow],str]=zokor.query_all(postgres.pool,
        "with snapshot_orders as ("+
        "select value from jsonb_array_elements($2::jsonb) as orders(value)), "+
        "actual_orders as ("+
        "select jsonb_build_object('id',o.id::text,'account_id',o.account_id::text,'owner_kind',o.owner_kind,"+
        "'owner_group',coalesce(o.owner_group::text,''),'outcome',o.outcome,'side',o.side,'limit',o.limit_price,"+
        "'qty',o.original_qty,'remaining',o.remaining_qty,'tif',o.tif,'accepted_seq',o.accepted_seq,"+
        "'fee_paid',o.fee_posted,'sedi_hold_id',o.sedi_hold_id::text,'share_hold_id',coalesce(o.share_hold_id::text,''),"+
        "'sedi_original',o.sedi_original,'sedi_consumed',o.sedi_consumed,'sedi_released',o.sedi_released,"+
        "'shares_original',o.shares_original,'shares_consumed',o.shares_consumed,'shares_released',o.shares_released,"+
        "'filled',o.filled_qty,'cancelled',o.cancelled_qty) as value from orders o "+
        "where o.market_id=$1::uuid and o.status in ('OPEN','PARTIAL') and o.remaining_qty>0), "+
        "order_diff as ("+
        "(select value from snapshot_orders except select value from actual_orders) "+
        "union all (select value from actual_orders except select value from snapshot_orders)), "+
        "hold_mismatch as ("+
        "select count(*)::bigint as n from orders o "+
        "left join holds sh on sh.id=o.sedi_hold_id left join wallets sw on sw.id=sh.wallet_id "+
        "left join holds qh on qh.id=o.share_hold_id left join wallets qw on qw.id=qh.wallet_id "+
        "where o.market_id=$1::uuid and ("+
        "sh.id is null or sh.ref_type<>'order' or sh.ref_id<>o.id::text or sh.season_id<>o.season_id or "+
        "sh.asset_key<>'SEDI' or sh.amount_held<>o.sedi_original or sh.amount_consumed<>o.sedi_consumed or "+
        "sh.amount_released<>o.sedi_released or "+
        "sh.amount_held-sh.amount_consumed-sh.amount_released<>o.sedi_original-o.sedi_consumed-o.sedi_released or "+
        "sh.status<>case when o.sedi_original-o.sedi_consumed-o.sedi_released>0 then 'open' else 'closed' end or "+
        "sw.owner_kind<>o.owner_kind or sw.owner_id<>o.account_id::text or sw.season_id<>o.season_id or sw.asset_key<>'SEDI' or "+
        "(o.side='SELL' and (qh.id is null or qh.ref_type<>'order' or qh.ref_id<>o.id::text or "+
        "qh.season_id<>o.season_id or qh.asset_key<>o.outcome||':'||o.market_id::text or "+
        "qh.amount_held<>o.shares_original or qh.amount_consumed<>o.shares_consumed or "+
        "qh.amount_released<>o.shares_released or "+
        "qh.amount_held-qh.amount_consumed-qh.amount_released<>o.shares_original-o.shares_consumed-o.shares_released or "+
        "qh.status<>case when o.shares_original-o.shares_consumed-o.shares_released>0 then 'open' else 'closed' end or "+
        "qw.owner_kind<>o.owner_kind or qw.owner_id<>o.account_id::text or qw.season_id<>o.season_id or "+
        "qw.asset_key<>o.outcome||':'||o.market_id::text)) or "+
        "(o.side='BUY' and o.share_hold_id is not null))), "+
        "orphan_holds as ("+
        "select count(*)::bigint as n from holds h join ledger_transactions t on t.id=h.opened_tx "+
        "where h.ref_type='order' and t.market_id=$1::uuid and not exists "+
        "(select 1 from orders o where o.id::text=h.ref_id and o.market_id=$1::uuid)), "+
        "position_mismatch as ("+
        "select count(*)::bigint as n from ("+
        "select p.qty as position_qty,w.free_units+w.held_units as wallet_qty from positions p "+
        "full join wallets w on w.owner_kind in ('user','bot') and w.owner_id=p.account_id::text "+
        "and w.season_id=p.season_id and w.asset_key=p.outcome||':'||p.market_id::text "+
        "where p.market_id=$1::uuid or w.asset_key in ('YES:'||$1::text,'NO:'||$1::text)) x "+
        "where coalesce(position_qty,0)<>coalesce(wallet_qty,0)), "+
        "market_mismatch as ("+
        "select count(*)::bigint as n from markets m where m.id=$1::uuid and "+
        "(m.committed_seq<>$3 or m.rolling_hash<>$4 or m.book_mode<>$5 or m.issued_pairs<>$6 or "+
        "m.issued_pairs::numeric*m.redemption_units<>$7::numeric or "+
        "coalesce((select sum(e.delta) from wallets w join ledger_entries e on e.wallet_id=w.id "+
        "where w.season_id=m.season_id and w.owner_kind='system' and "+
        "w.owner_id='system:collateral:'||m.id::text and w.asset_key='SEDI'),0)<>$7::numeric)) "+
        "select ((select count(*) from order_diff)+(select n from hold_mismatch)+"+
        "(select n from orphan_holds)+(select n from position_mismatch)+(select n from market_mismatch))::bigint as mismatches",
        [pg.arg_text(market_id),pg.arg_text(json.encode(snapshot.orders)),pg.arg_int(snapshot.last_seq),
         pg.arg_text(snapshot.state_hash),pg.arg_text(snapshot.mode),pg.arg_int(snapshot.pairs),
         pg.arg_int(snapshot.collateral)],deadline(postgres));
    guard let checked=rows else let e=err_of(rows) { return err(e); }
    return ok(checked[0].mismatches==0);
}

fn st_save_snapshot(postgres: Postgres, snapshot: service.SnapshotWrite) -> result[bool,str] {
    let rows:result[[SnapshotSavedRow],str]=zokor.query_all(postgres.pool,
        "insert into market_snapshots(market_id,committed_seq,book_seq,state_hash,payload,schema_version,owner_epoch,full_hash) "+
        "select m.id,$2,$2,$3,$4::jsonb,1,$6,$5 from markets m "+
        "join market_owners o on o.market_id=m.id and o.node_id=$7::uuid and o.epoch=$6 "+
        "join runtime_nodes n on n.id=o.node_id "+
        "where m.id=$1::uuid and m.committed_seq>=$2 and m.owner_epoch=$6 "+
        "and m.runtime_verified_epoch=$6 and o.lease_until>clock_timestamp() and n.live_until>clock_timestamp() "+
        "and (($2=0 and ((m.committed_seq=0 and m.rolling_hash=$3) or exists(select 1 from market_commands anchor where anchor.market_id=m.id and anchor.seq=1 and anchor.previous_hash=$3))) "+
        "or exists(select 1 from market_commands covered where covered.market_id=m.id and covered.seq=$2 and covered.state in ('DONE','REJECTED') and covered.state_hash=$3)) "+
        "on conflict(market_id,committed_seq) do nothing returning id::text as id",
        [pg.arg_text(snapshot.market_id),pg.arg_int(snapshot.committed_seq),pg.arg_text(snapshot.state_hash),
         pg.arg_text(snapshot.payload),pg.arg_text(snapshot.full_hash),pg.arg_int(snapshot.owner_epoch),
         pg.arg_text(snapshot.node_id)],deadline(postgres));
    guard let saved=rows else let e=err_of(rows) { return err(e); }
    return ok(len(saved)==1);
}

fn st_load_recovery(postgres: Postgres, market_id: str) -> result[service.RecoveryData,str] {
    return zokor.transaction(postgres.pool,
        RecoveryArg { postgres:postgres,market_id:market_id },load_recovery_tx,deadline(postgres));
}

fn load_recovery_tx(conn: pg.Conn,arg: RecoveryArg) -> result[service.RecoveryData,str] {
    let markets: result[[RecoveryMarketRow],str]=zokor.conn_query_all(conn,
        "select season_id::text as season_id,redemption_units as \"V\",min_price,max_price,tick,max_order_qty,"+
        "min_order_notional,issued_pairs,committed_seq,coalesce(rolling_hash,'') as rolling_hash,book_mode as mode "+
        "from markets where id=$1::uuid for share",
        [pg.arg_text(arg.market_id)],deadline(arg.postgres));
    guard let rows=markets else let e=err_of(markets) { return err(e); }
    if len(rows)!=1 { return err("MARKET_NOT_FOUND"); }
    let market=rows[0];
    if market.V<1 || market.committed_seq<0 || market.rolling_hash=="" { return err("RECOVERY_MARKET_INVALID"); }
    let stored_snapshots:result[[RecoverySnapshotRow],str]=zokor.conn_query_all(conn,
        "select committed_seq,state_hash,full_hash,schema_version,payload::text as payload "+
        "from market_snapshots where market_id=$1::uuid and committed_seq<=$2 and committed_seq>=greatest(0,$2-100000) "+
        "order by committed_seq desc limit 16",
        [pg.arg_text(arg.market_id),pg.arg_int(market.committed_seq)],deadline(arg.postgres));
    guard let snapshot_rows=stored_snapshots else let e=err_of(stored_snapshots) { return err(e); }
    let snapshots:[service.RecoverySnapshot]=[];
    for snapshot in snapshot_rows {
        push(snapshots,service.RecoverySnapshot {
            committed_seq:snapshot.committed_seq,state_hash:snapshot.state_hash,
            full_hash:snapshot.full_hash,schema_version:snapshot.schema_version,payload:snapshot.payload
        });
    }
    let base_seq=0;
    if market.committed_seq>100000 { base_seq=market.committed_seq-100000; }
    let loaded: result[[RecoveryStepRow],str]=zokor.conn_query_all(conn,
        "select seq,coalesce(resolved_input::text,'') as command_payload,"+
        "coalesce(transition::text,'') as transition_payload from market_commands "+
        "where market_id=$1::uuid and state in ('DONE','REJECTED') and seq>0 and seq<=$2 "+
        "and ($3=0 or seq>=$3) order by seq limit 100001",
        [pg.arg_text(arg.market_id),pg.arg_int(market.committed_seq),pg.arg_int(base_seq)],deadline(arg.postgres));
    guard let steps=loaded else let e=err_of(loaded) { return err(e); }
    let recovery_steps: [service.RecoveryStep]=[];
    for step in steps {
        push(recovery_steps,service.RecoveryStep {
            seq:step.seq,command_payload:step.command_payload,transition_payload:step.transition_payload
        });
    }
    return ok(service.RecoveryData {
        policy:core.Policy {
            market_id:arg.market_id,season_id:market.season_id,V:market.V,
            min_price:market.min_price,max_price:market.max_price,tick:market.tick,
            max_order_qty:market.max_order_qty,min_order_notional:market.min_order_notional
        },
        pairs:market.issued_pairs,committed_seq:market.committed_seq,rolling_hash:market.rolling_hash,
        mode:market.mode,base_seq:base_seq,snapshots:snapshots,steps:recovery_steps
    });
}

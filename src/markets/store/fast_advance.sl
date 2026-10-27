import "pg";
import "zokor";
import "../domain" as domain;
import "../service" as service;

gc struct FastAdvance { store: Store, command: service.Command }

fn fast_advance_tx(c: pg.Conn,a: FastAdvance) -> result[opt[domain.Market],str] {
    let cmd=a.command;
    let query=
        "with season_guard as materialized ( " +
        " select s.id,s.status,s.ends_at from seasons s join markets x on x.season_id=s.id " +
        " where x.id=$1::uuid for share of s " +
        "), prior as materialized ( " +
        " select m.id,m.status,m.version from markets m join season_guard s on s.id=m.season_id " +
        " where m.id=$1::uuid and m.version=$2 and " +
        " (m.status='CLOSED' or (m.status in ('OPEN','SUSPENDED') and " +
        " (m.close_at<=to_timestamp($3::bigint/1000.0) or s.status<>'ACTIVE' or s.ends_at<=to_timestamp($3::bigint/1000.0)))) " +
        " for update of m " +
        "), changed as ( " +
        " update markets m set status=case when p.status='CLOSED' then 'RESOLUTION_PENDING' else 'CLOSED' end, " +
        " version=m.version+1,updated_at=to_timestamp($3::bigint/1000.0), " +
        " closed_at=coalesce(m.closed_at,to_timestamp($3::bigint/1000.0)), " +
        " status_note=case when p.status='CLOSED' then 'Collecting results' else 'Market closed' end " +
        " from prior p where m.id=p.id and m.version=p.version returning m.*,p.status as previous_status " +
        "), audited as ( " +
        " insert into audit_events(actor_id,action,target_type,target_id,detail,created_at) " +
        " select null,case when m.status='CLOSED' then 'market.closed' else 'market.resolution_pending' end, " +
        " 'market',m.id::text,jsonb_build_object('market_id',m.id,'season_id',m.season_id,'from',m.previous_status, " +
        " 'status',m.status,'version',m.version,'terms_version',m.terms_version,'reason',$4::text), " +
        " to_timestamp($3::bigint/1000.0) from changed m " +
        "), emitted as ( " +
        " insert into outbox_events(market_id,type,payload,created_at) " +
        " select m.id,case when m.status='CLOSED' then 'market.closed' else 'market.resolution_pending' end, " +
        " jsonb_build_object('market_id',m.id,'season_id',m.season_id,'from',m.previous_status,'status',m.status, " +
        " 'version',m.version,'terms_version',m.terms_version,'reason',$4::text),to_timestamp($3::bigint/1000.0) from changed m " +
        ") " +
        " select coalesce(m.id::text,'') as id, coalesce(m.slug::text,'') as slug, coalesce(m.question::text,'') as question, coalesce(m.category_id::text,'') as category_id, coalesce(m.season_id::text,'') as season_id, coalesce(m.resolution_source_id::text,'') as resolution_source_id, coalesce(m.rules->>'yes_if','') as yes_if, coalesce(m.rules->>'no_if','') as no_if, coalesce(m.rules->>'edge_cases','') as edge_cases, coalesce((extract(epoch from m.open_at)*1000)::bigint,0) as open_at, coalesce((extract(epoch from m.close_at)*1000)::bigint,0) as close_at, coalesce((extract(epoch from m.resolve_by)*1000)::bigint,0) as resolve_by, coalesce(m.redemption_units,0) as redemption_units, coalesce(m.min_price,0) as min_price, coalesce(m.max_price,0) as max_price, coalesce(m.tick,0) as tick, coalesce(m.max_order_qty,0) as max_order_qty, coalesce(m.fee_units,0) as fee_units, coalesce(m.min_order_notional,0) as min_order_notional, coalesce(m.liquidity_request,0) as liquidity_request, coalesce(m.featured_rank,0) as featured_rank, coalesce(m.opening_price,0) as opening_price, coalesce(m.status::text,'') as status, coalesce(m.version,0) as version, coalesce(m.terms_version,0) as terms_version, coalesce(m.terms_hash::text,'') as terms_hash, coalesce(m.created_by::text,'') as created_by, coalesce(m.submitted_by::text,'') as submitted_by, coalesce(m.approved_by::text,'') as approved_by, coalesce((extract(epoch from m.created_at)*1000)::bigint,0) as created_at, coalesce((extract(epoch from m.updated_at)*1000)::bigint,0) as updated_at, coalesce((extract(epoch from m.opened_at)*1000)::bigint,0) as opened_at, coalesce((extract(epoch from m.closed_at)*1000)::bigint,0) as closed_at, coalesce((extract(epoch from m.suspended_at)*1000)::bigint,0) as suspended_at, coalesce(m.suspend_reason::text,'') as suspend_reason, coalesce(m.status_note::text,'') as status_note from changed m ";
    let r: result[[domain.Market],str]=zokor.conn_query_all(c,query,
        [pg.arg_text(cmd.id),pg.arg_int(cmd.version),pg.arg_int(cmd.now),pg.arg_text(cmd.reason)],deadline(a.store));
    guard let rows=r else let e=err_of(r) { return err(e); }
    let missing: opt[domain.Market]=none;
    if len(rows)==0 { return ok(missing); }
    return ok(some(rows[0]));
}

fn fast_advance(s: Store,cmd: service.Command) -> result[opt[domain.Market],str] {
    return zokor.transaction(s.pool,FastAdvance { store:s,command:cmd },fast_advance_tx,deadline(s));
}

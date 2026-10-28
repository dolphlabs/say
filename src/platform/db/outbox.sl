import "pg";
import "time";
import "zokor";
import "../cache" as cache;

gc struct RuntimeEvent {
    id: str,
    market_id: str,
    account_id: str,
    audience: str,
    market_seq: int,
    event_ordinal: int,
    owner_epoch: int,
    type: str,
    payload: str,
    claim_token: str
}

gc struct ClaimEventsArg { limit: int, timeout: int }
gc struct ClaimedEventRow {
    id: str,
    market_id: str,
    account_id: str,
    audience: str,
    market_seq: int,
    event_ordinal: int,
    owner_epoch: int,
    type: str,
    payload: str,
    claim_token: str
}
gc struct EventClaimArg { event_id: str, claim_token: str, timeout: int }
gc struct EventMarkArg { event_id: str, claim_token: str, timeout: int }
gc struct OutboxIdRow { id: str }
gc struct LegacyEvent {
    id: str,
    type: str,
    payload: str,
    claim_token: str
}
gc struct LegacyClaimArg { limit: int, timeout: int }

fn claim_legacy_events_tx(conn: pg.Conn,arg: LegacyClaimArg) -> result[[LegacyEvent],str] {
    let d=until_of(time.mono()+arg.timeout);
    return zokor.conn_query_all(conn,
        "with heads as ("+
        "select id from outbox_events where audience='legacy' and published_at is null "+
        "and next_attempt_at<=clock_timestamp() and (claim_until is null or claim_until<=clock_timestamp()) "+
        "order by created_at,id limit $1 for update skip locked) "+
        "update outbox_events e set claim_node=gen_random_uuid(),"+
        "claim_until=clock_timestamp()+interval '10 seconds',attempt_count=attempt_count+1 "+
        "from heads h where e.id=h.id returning e.id::text as id,e.type,e.payload::text as payload,"+
        "e.claim_node::text as claim_token",
        [pg.arg_int(arg.limit)],d);
}

fn claim_legacy_events(pool: pg.Pool,limit: int,timeout: int) -> result[[LegacyEvent],str] {
    return zokor.transaction(pool,LegacyClaimArg { limit:limit,timeout:timeout },
        claim_legacy_events_tx,until_of(time.mono()+timeout));
}

fn claim_runtime_events_tx(conn: pg.Conn,arg: ClaimEventsArg) -> result[[ClaimedEventRow],str] {
    let d=until_of(time.mono()+arg.timeout);
    return zokor.conn_query_all(conn,
        "with heads as ("+
        "select e.id from outbox_events e where e.audience<>'legacy' and e.published_at is null "+
        "and e.next_attempt_at<=clock_timestamp() and (e.claim_until is null or e.claim_until<=clock_timestamp()) "+
        "and not exists (select 1 from outbox_events p where p.audience=e.audience and p.market_id=e.market_id "+
        "and p.account_id is not distinct from e.account_id and p.published_at is null "+
        "and (p.market_seq,p.event_ordinal)<(e.market_seq,e.event_ordinal)) "+
        "order by e.market_id,e.audience,e.account_id,e.market_seq,e.event_ordinal limit $1 for update of e skip locked) "+
        "update outbox_events e set claim_node=gen_random_uuid(),claim_until=clock_timestamp()+interval '10 seconds',"+
        "attempt_count=attempt_count+1 from heads h where e.id=h.id "+
        "returning e.id::text as id,e.market_id::text as market_id,coalesce(e.account_id::text,'') as account_id,"+
        "e.audience,e.market_seq,e.event_ordinal,e.owner_epoch,e.type,e.payload::text as payload,e.claim_node::text as claim_token",
        [pg.arg_int(arg.limit)],d);
}

fn claim_runtime_events(pool: pg.Pool,limit: int,timeout: int) -> result[[ClaimedEventRow],str] {
    return zokor.transaction(pool,ClaimEventsArg { limit:limit,timeout:timeout },
        claim_runtime_events_tx,until_of(time.mono()+timeout));
}

fn acknowledge_event_tx(conn: pg.Conn,arg: EventMarkArg) -> result[bool,str] {
    let d=until_of(time.mono()+arg.timeout);
    let rows: result[[OutboxIdRow],str]=zokor.conn_query_all(conn,
        "update outbox_events set published_at=clock_timestamp(),claim_node=null,claim_until=null "+
        "where id=$1::uuid and claim_node=$2::uuid and published_at is null "+
        "returning id::text as id",
        [pg.arg_text(arg.event_id),pg.arg_text(arg.claim_token)],d);
    guard let updated=rows else let e=err_of(rows) { return err(e); }
    return ok(len(updated)==1);
}

fn acknowledge_event(pool: pg.Pool,event: ClaimedEventRow,timeout: int) -> result[bool,str] {
    return zokor.transaction(pool,EventMarkArg { event_id:event.id,claim_token:event.claim_token,timeout:timeout },
        acknowledge_event_tx,until_of(time.mono()+timeout));
}

fn acknowledge_event_id(pool: pg.Pool,event_id: str,claim_token: str,timeout: int) -> result[bool,str] {
    return zokor.transaction(pool,EventMarkArg { event_id:event_id,claim_token:claim_token,timeout:timeout },
        acknowledge_event_tx,until_of(time.mono()+timeout));
}

fn fail_event_tx(conn: pg.Conn,arg: EventMarkArg) -> result[bool,str] {
    let d=until_of(time.mono()+arg.timeout);
    let rows: result[[OutboxIdRow],str]=zokor.conn_query_all(conn,
        "update outbox_events set claim_node=null,claim_until=null,"+
        "next_attempt_at=clock_timestamp()+make_interval(secs=>least(60,power(2,least(attempt_count,6))::integer)) "+
        "where id=$1::uuid and claim_node=$2::uuid and published_at is null "+
        "returning id::text as id",
        [pg.arg_text(arg.event_id),pg.arg_text(arg.claim_token)],d);
    guard let updated=rows else let e=err_of(rows) { return err(e); }
    return ok(len(updated)==1);
}

fn fail_event(pool: pg.Pool,event: ClaimedEventRow,timeout: int) -> result[bool,str] {
    return zokor.transaction(pool,EventMarkArg { event_id:event.id,claim_token:event.claim_token,timeout:timeout },
        fail_event_tx,until_of(time.mono()+timeout));
}

fn fail_event_id(pool: pg.Pool,event_id: str,claim_token: str,timeout: int) -> result[bool,str] {
    return zokor.transaction(pool,EventMarkArg { event_id:event_id,claim_token:claim_token,timeout:timeout },
        fail_event_tx,until_of(time.mono()+timeout));
}

pub fn publish_legacy_outbox(d: Db,c: cache.Cache,limit: int,timeout_ns: int) -> result[int,str] {
    if limit<1 || limit>500 || timeout_ns<1000000 { return err("invalid legacy outbox batch"); }
    let claimed=claim_legacy_events(d.pool,limit,timeout_ns);
    guard let events=claimed else let e=err_of(claimed) { return err("legacy outbox claim failed: "+e); }
    let sent=0;
    let first_error="";
    for event in events {
        let appended=cache.xadd(c,"say:events",100000,["id",event.id,"type",event.type,"payload",event.payload]);
        if let _ok=appended {
            let ack=acknowledge_event_id(d.pool,event.id,event.claim_token,timeout_ns);
            guard let acknowledged=ack else let e=err_of(ack) {
                if first_error=="" { first_error="legacy outbox acknowledge failed for "+event.id+": "+e; }
                continue;
            }
            if acknowledged { sent+=1; }
            else if first_error=="" { first_error="legacy outbox claim expired before acknowledge for "+event.id; }
        } else let e=err_of(appended) {
            let retry=fail_event_id(d.pool,event.id,event.claim_token,timeout_ns);
            guard let _retry=retry else let retry_error=err_of(retry) {
                if first_error=="" { first_error="legacy outbox retry update failed for "+event.id+": "+retry_error; }
                continue;
            }
            if first_error=="" { first_error="legacy outbox delivery failed for "+event.id+": "+e; }
        }
    }
    if first_error!="" { return err(first_error); }
    return ok(sent);
}

pub fn publish_runtime_outbox(d: Db,c: cache.Cache,node_id: str,limit: int,timeout_ns: int) -> result[int,str] {
    if limit<1 || limit>500 || timeout_ns<1000000 { return err("invalid outbox batch"); }
    if len(node_id)!=36 { return err("invalid outbox publisher node"); }
    let pool=d.pool;
    let claimed=claim_runtime_events(pool,limit,timeout_ns);
    guard let events=claimed else let e=err_of(claimed) { return err("outbox claim failed: "+e); }
    let sent=0;
    let first_error="";
    for event in events {
        let stream="stream:market:"+event.market_id;
        if event.audience=="account" { stream="stream:account:"+event.account_id; }
        let fields=["id",event.id,"type",event.type,"payload",event.payload,
            "market_id",event.market_id,"market_seq",to_str(event.market_seq),
            "event_ordinal",to_str(event.event_ordinal),"owner_epoch",to_str(event.owner_epoch)];
        let appended=cache.xadd_ordered(c,stream,event.market_id,100000,event.market_seq,event.event_ordinal,fields);
        if let _ok=appended {
            let ack=acknowledge_event(pool,event,timeout_ns);
            guard let acknowledged=ack else let e=err_of(ack) {
                if first_error=="" { first_error="outbox acknowledge failed for "+event.id+": "+e; }
                continue;
            }
            if !acknowledged && first_error=="" {
                first_error="outbox claim expired before acknowledge for "+event.id;
            }
            if acknowledged { sent+=1; }
        } else let e=err_of(appended) {
            let retried=fail_event(pool,event,timeout_ns);
            guard let _retry=retried else let retry_error=err_of(retried) {
                if first_error=="" { first_error="outbox retry update failed for "+event.id+": "+retry_error; }
                continue;
            }
            if first_error=="" { first_error="outbox delivery failed for "+event.id+": "+e; }
        }
    }
    if first_error!="" { return err(first_error); }
    return ok(sent);
}

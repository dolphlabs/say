import "json";
import "time";
import "strings";
import "../../exchange/service" as exchange;
import "../../exchange/store" as exchange_store;
import "../metrics" as metrics;
import "../../accounts/service" as accounts;

pub fn order_rate_limited(a: App,account_id: str) -> bool {
    if let _limited=accounts.allow(a.accounts,accounts.Rule {
        name:"exchange_orders",limit:120,window_seconds:1
    },account_id) { return true; }
    return false;
}

pub gc struct RuntimeControl {
    lock: mutex,
    live: bool,
    active: map[str]bool,
    epochs: map[str]int,
    leases: map[str]int
}

fn new_runtime_control() -> RuntimeControl {
    let active:map[str]bool={};
    let epochs:map[str]int={};
    let leases:map[str]int={};
    return RuntimeControl { lock:make_mutex(),live:true,active:active,epochs:epochs,leases:leases };
}

pub fn start_exchange_workers(a: App) {
    spawn run_exchange_heartbeat(a);
    spawn run_exchange_supervisor(a);
}

pub fn await_order(a: App,account_id: str,order_id: str,cancel: bool) -> opt[exchange.ReadOrder] {
    let empty:opt[exchange.ReadOrder]=none;
    let wait=a.settings.exchange.reply_wait_ns;
    if wait==0 { return empty; }
    select {
        case chan_send(a.reply_slots,1) {}
        default { return empty; }
    }
    let end=time.mono()+wait;
    while time.mono()<end {
        let remaining=end-time.mono();
        let store=exchange_store.read_store(exchange_store.new_postgres(a.exchange_reads.context.pool,remaining as int));
        let loaded=exchange.read_order(store,account_id,order_id);
        if let found=loaded {
            if let order=found {
                let final=order.status!="ADMITTED";
                if cancel { final=order.status!="ADMITTED" && order.status!="OPEN" && order.status!="PARTIAL"; }
                if final { let _slot=chan_recv(a.reply_slots); return some(order); }
            }
        } else let e=err_of(loaded) {
            metrics.add(a.metrics,"exchange_reply_read_failures_total",1);
            break;
        }
        let sleep=end-time.mono();
        if sleep>50000000 { sleep=50000000; }
        if sleep>0 { time.sleep(sleep); }
    }
    let _slot=chan_recv(a.reply_slots);
    metrics.add(a.metrics,"exchange_reply_deadlines_total",1);
    return empty;
}

fn runtime_lease(a: App,market_id: str,epoch: int) -> int {
    mutex_lock(a.runtime.lock);
    let lease=0;
    if a.runtime.live && has(a.runtime.epochs,market_id) && a.runtime.epochs[market_id]==epoch {
        lease=a.runtime.leases[market_id];
    }
    mutex_unlock(a.runtime.lock);
    return lease;
}

fn run_exchange_heartbeat(a: App) -> int {
    while true {
        let ids:[str]=[];
        let epochs:[int]=[];
        mutex_lock(a.runtime.lock);
        for id,epoch in a.runtime.epochs {
            push(ids,id);
            push(epochs,epoch);
        }
        mutex_unlock(a.runtime.lock);
        let start=0;
        let first=true;
        while first || start<len(ids) {
            first=false;
            let end=start+500;
            if end>len(ids) { end=len(ids); }
            let batch_ids:[str]=[];
            let batch_epochs:[int]=[];
            let expected_epochs:map[str]int={};
            for i in start..end { push(batch_ids,ids[i]); push(batch_epochs,epochs[i]); expected_epochs[ids[i]]=epochs[i]; }
            let until_ms=time.wall()/1000000+a.settings.exchange.lease_seconds*1000;
            let outcome=exchange.heartbeat(a.heartbeat_ownership,a.node_id,a.settings.exchange.lease_seconds,batch_ids,batch_epochs);
            if let beat=outcome {
                mutex_lock(a.runtime.lock);
                if !beat.node_live { a.runtime.live=false; }
                for i in 0..len(beat.markets) {
                    let lease=beat.markets[i];
                    if has(a.runtime.epochs,lease.market_id) && a.runtime.epochs[lease.market_id]==expected_epochs[lease.market_id] {
                        if beat.node_live && lease.renewed { a.runtime.leases[lease.market_id]=until_ms; }
                        else { a.runtime.leases[lease.market_id]=0; }
                    }
                }
                mutex_unlock(a.runtime.lock);
                if !beat.node_live {
                    a.settings.server.logger.error("exchange","runtime node expired; trading tasks stopped");
                    metrics.add(a.metrics,"exchange_runtime_node_expired_total",1);
                    return 0;
                }
            } else let e=err_of(outcome) {
                a.settings.server.logger.warn("exchange","runtime heartbeat failed: "+e);
                metrics.add(a.metrics,"exchange_runtime_heartbeat_failures_total",1);
                break;
            }
            start=end;
        }
        time.sleep(a.settings.exchange.heartbeat_ns);
    }
    return 0;
}

fn run_exchange_supervisor(a: App) -> int {
    let after="";
    while true {
        mutex_lock(a.runtime.lock);
        let live=a.runtime.live;
        mutex_unlock(a.runtime.lock);
        if !live { return 0; }
        let found=exchange.candidates(a.ownership,after,500);
        if let ids=found {
            if len(ids)<500 { after=""; }
            else { after=ids[len(ids)-1]; }
            for id in ids {
                mutex_lock(a.runtime.lock);
                let start=!has(a.runtime.active,id) && len(a.runtime.active)<a.settings.exchange.max_actors;
                if start { a.runtime.active[id]=true; }
                mutex_unlock(a.runtime.lock);
                if start { spawn run_market_task(a,id); }
            }
        } else let e=err_of(found) {
            a.settings.server.logger.warn("exchange","market discovery failed: "+e);
        }
        time.sleep(a.settings.exchange.poll_ns);
    }
    return 0;
}

fn run_market_task(a: App,id: str) -> int {
    let lease_until=time.wall()/1000000+a.settings.exchange.lease_seconds*1000;
    let claimed=exchange.acquire(a.ownership,id,a.node_id,a.settings.exchange.lease_seconds);
    let epoch=0;
    if let claim=claimed {
        if claim.acquired || claim.renewed {
            epoch=claim.epoch;
            mutex_lock(a.runtime.lock);
            a.runtime.epochs[id]=epoch;
            a.runtime.leases[id]=lease_until;
            mutex_unlock(a.runtime.lock);
            let outcome=run_market(a,id,epoch);
            if let _done=outcome {} else let e=err_of(outcome) {
                a.settings.server.logger.error("exchange","market stopped for recovery "+id+": "+e);
                metrics.add(a.metrics,"exchange_runtime_actor_failures_total",1);
            }
            invalidate_runtime_view(a,id);
            mutex_lock(a.runtime.lock);
            del(a.runtime.epochs,id);
            del(a.runtime.leases,id);
            mutex_unlock(a.runtime.lock);
            let released=exchange.release(a.ownership,id,a.node_id,epoch);
            if let _released=released {} else let e=err_of(released) {
                a.settings.server.logger.warn("exchange","market lease release failed for "+id+": "+e);
            }
        }
    } else let e=err_of(claimed) {
        a.settings.server.logger.warn("exchange","market ownership claim failed for "+id+": "+e);
    }
    mutex_lock(a.runtime.lock);
    del(a.runtime.active,id);
    mutex_unlock(a.runtime.lock);
    return 0;
}

fn run_market(a: App,id: str,epoch: int) -> result[bool,str] {
    let recovered=exchange.recover_book(a.recovery_store,id,128);
    guard let book=recovered else let e=err_of(recovered) {
        metrics.add(a.metrics,"exchange_runtime_recovery_failures_total",1);
        if strings.has_prefix(e,"RECOVERY_") {
            let quarantined=a.recovery_store.quarantine(a.recovery_store.context,id,a.node_id,epoch,e);
            if let _quarantined=quarantined {} else let failure=err_of(quarantined) {
                a.settings.server.logger.error("exchange","quarantine failed for "+id+": "+failure);
            }
        }
        return err(e);
    }
    let workspace=exchange.workspace_for(&book,128);
    let created=exchange.new_actor(a.actor_writer,book,workspace,a.node_id,epoch);
    guard let actor=created else let e=err_of(created) { return err(e); }
    let captured=exchange.snapshot_write(actor);
    guard let snapshot=captured else let e=err_of(captured) { return err(e); }
    let verified=a.recovery_store.verify_epoch(a.recovery_store.context,snapshot,
        a.settings.exchange.pending_limit,a.settings.exchange.control_limit);
    guard let book_seq=verified else let e=err_of(verified) { return err(e); }
    let cursor=0;
    let ready=false;
    let snapshot_seq=actor.book.last_seq;
    let snapshot_at=time.mono();
    let snapshot_attempt_at=time.mono();
    while true {
        let lease=runtime_lease(a,id,epoch);
        if lease<=time.wall()/1000000 { return err("OWNER_LEASE_EXPIRED"); }
        let synced=exchange.sync_lifecycle(a.command_queue,id);
        guard let pending=synced else let e=err_of(synced) { return err(e); }
        let loaded=exchange.load_pending(a.command_queue,id,cursor,64);
        guard let batch=loaded else let e=err_of(loaded) { return err(e); }
        for command in batch.commands {
            if runtime_lease(a,id,epoch)<=time.wall()/1000000 { return err("OWNER_LEASE_EXPIRED"); }
            let previous_mode=actor.book.mode;
            let processed=exchange.process_one(actor,command);
            guard let transition=processed else let e=err_of(processed) { return err(e); }
            cursor=command.command_id;
            if len(transition.book_deltas)>0 || transition.mode!=previous_mode { book_seq=transition.seq; }
            pending-=1;
            if pending<0 { pending=0; }
            publish_actor_view(a,actor,book_seq,pending,ready);
            metrics.add(a.metrics,"exchange_runtime_commands_total",1);
        }
        if len(batch.commands)==0 {
            cursor=batch.frontier;
            if !ready {
                let marked=exchange.mark_ready(a.ownership,id,a.node_id,epoch);
                guard let is_ready=marked else let e=err_of(marked) { return err(e); }
                ready=is_ready;
            }
            publish_actor_view(a,actor,book_seq,pending,ready);
        }
        let now=time.mono();
        if actor.book.last_seq-snapshot_seq>=a.settings.exchange.snapshot_commands ||
           now-snapshot_at>=a.settings.exchange.snapshot_every_ns {
            if now-snapshot_attempt_at>=1000000000 {
                snapshot_attempt_at=now;
                if queue_snapshot(a,actor) { snapshot_seq=actor.book.last_seq; snapshot_at=now; }
            }
        }
        if len(batch.commands)==0 { time.sleep(a.settings.exchange.poll_ns); }
    }
    return ok(true);
}

fn publish_actor_view(a: App,actor: exchange.Actor[exchange_store.Postgres],book_seq: int,pending: int,ready: bool) {
    let at=time.wall()/1000000;
    let health="RECOVERING";
    if ready { health="READY"; }
    let lease=runtime_lease(a,actor.book.policy.market_id,actor.epoch);
    let view=exchange.book_view(&actor.book,actor.epoch,pending,health,at,lease);
    view.book_seq=book_seq;
    publish_runtime_view(a,view);
}

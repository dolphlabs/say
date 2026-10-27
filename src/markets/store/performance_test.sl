import "pg";
import "proc";
import "time";
import "timez";
import "../domain" as domain;
import "../service" as service;

fn fixture_open(r: Rig,i: int) -> domain.Market {
    let id="00000000-0000-4000-a000-"+to_str(100000000000+i);
    let p=full_patch(r); p.close_at=some(10000000+(i%5)*1000);
    let created=changed(r,cmd("create",id,r.author,0,p,2000));
    let review=changed(r,cmd("submit",id,r.author,created.version,domain.empty_patch(),2000));
    let approved=changed(r,cmd("approve",id,r.curator,review.version,domain.empty_patch(),2000));
    let funding=changed(r,cmd("advance",id,"",approved.version,domain.empty_patch(),2000));
    return changed(r,cmd("advance",id,"",funding.version,domain.empty_patch(),2000));
}

fn no_id() -> str { panic("This benchmark does not create through the service."); }

fn test_closing_1000_markets_in_five_seconds() {
    if (proc.getenv("MARKET_LOAD") ?? "")!="1" { println("skip registry close benchmark (MARKET_LOAD is not 1)"); return; }
    guard let r=rig() else { return; }
    let i=0;
    while i<1000 {
        let end=i+8; if end>1000 { end=1000; }
        let tasks: [join[domain.Market]]=[];
        for index in i..end { push(tasks,spawn fixture_open(r,index)); }
        for task in tasks { let joined=join_wait(task); guard let _m=joined else let e=err_of(joined) { panic(e); } }
        i=end;
    }
    let port=on_postgres(r.store.pool,r.store.timeout,r.store.coordinator,r.store.zone);
    let s=service.new_markets(port,no_id,timez.fixed_clock(timez.unix(10000)));
    let origin=time.mono();
    let maximum_bound=0;
    while (time.mono()-origin)<5500000000 {
        let elapsed=((time.mono()-origin) as int)/1000000;
        let now=10000000+elapsed;
        let dr=due(r.store,now); guard let rows=dr else let e=err_of(dr) { panic(e); }
        let earliest=0;
        for m in rows { if m.status=="OPEN" && (earliest==0 || m.close_at<earliest) { earliest=m.close_at; } }
        assert(service.advance_batch(s,rows,now),"close batch failed");
        if earliest>0 {
            let completed=10000000+((time.mono()-origin) as int)/1000000;
            let bound=completed-earliest;
            if bound>maximum_bound { maximum_bound=bound; }
        }
        time.sleep(50000000);
    }
    let closed=number(r.owner,"select count(*)::bigint as value from markets where status in ('CLOSED','RESOLUTION_PENDING')",[]);
    println("MARKET_CLOSE markets=1000 deadline_span_ms=4000 workers=8 committed="+to_str(closed)+" maximum_batch_completion_lateness_bound_ms="+to_str(maximum_bound));
    assert(closed==1000 && maximum_bound<=1000,"close deadline gate failed");
    close(r);
}

fn test_scheduler_leadership_and_boot_catchup() {
    guard let r=rig() else { return; }
    let first=lease_try(r.store,7310010); guard let got=first else { panic("lease"); }
    guard let lease=got else { panic("first leader missing"); }
    let second=lease_try(r.store,7310010); guard let other=second else { panic("second lease"); }
    if let _l=other { panic("two leaders"); }
    lease_release(r.store,lease);
    let third=lease_try(r.store,7310010); guard let reacquired=third else { panic("reacquire"); }
    guard let next=reacquired else { panic("leadership never released"); }
    lease_release(r.store,next);
    let m=fixture_open(r,0);
    let rows=due(r.store,m.close_at+5000); guard let pending_=rows else { panic("overdue scan"); }
    assert(len(pending_)==1 && pending_[0].id==m.id);
    let closed=changed(r,cmd("advance",m.id,"",m.version,domain.empty_patch(),m.close_at+5000));
    assert(closed.status=="CLOSED");
    close(r);
}

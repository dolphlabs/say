import "proc";
import "time";
import "zokor";
import "../domain" as domain;
import "../service" as markets;

fn percentile(samples: [int],pct: int) -> int {
    let sorted: [int]=[];
    for value in samples {
        push(sorted,value);
        let i=len(sorted)-1;
        while i>0 && sorted[i]<sorted[i-1] { let previous=sorted[i-1]; sorted[i-1]=sorted[i]; sorted[i]=previous; i-=1; }
    }
    return sorted[(len(sorted)-1)*pct/100];
}

fn test_warm_cache_router_latency_for_1000_markets() {
    if (proc.getenv("MARKET_LOAD") ?? "")!="1" { println("skip market cache benchmark (MARKET_LOAD is not 1)"); return; }
    guard let r=http_rig() else { return; }
    let loaded=markets.refresh(r.state.markets); guard let generation=loaded else { panic("refresh"); }
    let captured=markets.snapshot(r.state.markets); guard let before=captured else { panic("snapshot"); }
    let rows: [domain.Market]=[];
    let prices: [markets.Stats]=[];
    let now=r.state.markets.clock.now().unix_milli();
    for i in 0..1000 {
        let id="00000000-0000-4000-a000-"+to_str(100000000000+i);
        let m=domain.draft(id,"benchmark-author",now-i*1000);
        m.slug="benchmark-"+id; m.question="Will this benchmark event finish with a Yes result?";
        m.status="OPEN"; m.category_id="00000000-0000-4000-a000-000000000101";
        m.close_at=now+7200000+i*1000; m.redemption_units=100; m.min_price=1; m.max_price=99;
        push(rows,m);
        if i%2==0 { push(prices,markets.Stats { market_id:id,last_price:some(60),yes_bid:some(59),yes_ask:some(61),
            no_bid:some(39),no_ask:some(41),volume_units:some(100000+i),volume_24h_units:some(i),players:some(20),change_24h:some("1.5") }); }
    }
    let data=markets.new_snapshot(rows,before.categories,before.sources,prices,before.seasons,now);
    data.generation=generation+1;
    r.state.markets.current=some(data);
    guard let app_db=r.state.db else { panic("db"); }
    db_close_http(r,app_db);
    let path="/v1/markets/"+rows[0].id;
    for i in 0..100 {
        let list=req(r,zokor.Method.GET,"/v1/markets?filter=trending&status=open","","");
        let detail_=req(r,zokor.Method.GET,path,"","");
        assert(zokor.resp_status(list)==200 && zokor.resp_status(detail_)==200);
    }
    let lists: [int]=[]; let details: [int]=[];
    for i in 0..500 {
        let start=time.mono();
        let list=req(r,zokor.Method.GET,"/v1/markets?filter=trending&status=open","","");
        push(lists,(time.mono()-start) as int);
        let detail_start=time.mono();
        let detail_=req(r,zokor.Method.GET,path,"","");
        push(details,(time.mono()-detail_start) as int);
        assert(zokor.resp_status(list)==200 && zokor.resp_status(detail_)==200);
    }
    let list_p99=percentile(lists,99); let detail_p99=percentile(details,99);
    println("MARKET_CACHE markets=1000 samples=500 warmup=100 list_p50_ns="+to_str(percentile(lists,50))+" list_p99_ns="+to_str(list_p99)+
        " detail_p50_ns="+to_str(percentile(details,50))+" detail_p99_ns="+to_str(detail_p99));
    assert(list_p99<5000000 && detail_p99<5000000,"warm cache p99 exceeded 5ms");
}

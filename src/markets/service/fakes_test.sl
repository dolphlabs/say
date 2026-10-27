import "timez";
import "../domain" as domain;

gc struct Fake { commands: [Command], rows: [domain.Market], failure: str }

fn fake_mutate(f: Fake,c: Command) -> result[domain.Market,Failed] {
    push(f.commands,c);
    if len(f.failure)>0 { return err(failure("UNAVAILABLE",f.failure)); }
    return ok(domain.patched(domain.draft(c.id,c.actor_id,c.now),c.patch));
}
fn fake_find(f: Fake,id: str,actor: str) -> result[opt[domain.Market],Failed] {
    for m in f.rows { if m.id==id || m.slug==id { return ok(some(m)); } }
    let missing: opt[domain.Market]=none;
    return ok(missing);
}
fn fake_snapshot(f: Fake,now: int) -> result[Snapshot,str] {
    if len(f.failure)>0 { return err(f.failure); }
    return ok(new_snapshot(f.rows,[],[],[],[],now));
}
fn fake_due(f: Fake,now: int) -> result[[domain.Market],str] { return ok(f.rows); }
fn fake_history(f: Fake,id: str,actor: str) -> result[str,Failed] { return ok("{}"); }
fn fake_source(f: Fake,actor: str,name: str,url: str,kind: str,now: int) -> result[Source,Failed] {
    return ok(Source { id:"source",name:name,url_pattern:url,kind:kind,approved:false });
}
fn fake_lease(f: Fake,key: int) -> result[opt[int],str] { let missing: opt[int]=none; return ok(missing); }
fn fake_release(f: Fake,key: int) {}
fn fake_validate(f: Fake,m: domain.Market,full: bool,now: int) -> result[[domain.Problem],Failed] {
    return ok(domain.validate(m,full,domain.Facts { season_status:"ACTIVE",season_start:0,season_end:100000000,
        source_approved:true,category_exists:true },now));
}
fn fake_id() -> str { return "11111111-1111-4111-a111-111111111111"; }
fn fake_service(f: Fake) -> Markets[Fake] {
    return new_markets(MarketStore[Fake] { context:f,mutate:fake_mutate,find:fake_find,snapshot:fake_snapshot,
        due:fake_due,history:fake_history,source_create:fake_source,lease_try:fake_lease,lease_release:fake_release,
        validate:fake_validate },fake_id,timez.fixed_clock(timez.unix(100)));
}

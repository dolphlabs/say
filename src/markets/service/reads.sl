import "strings";
import "../domain" as domain;

pub fn new_snapshot(markets: [domain.Market],categories: [Category],sources: [Source],stats: [Stats],seasons: [Season],now: int) -> Snapshot {
    let ids: map[str]domain.Market={};
    let slugs: map[str]domain.Market={};
    let prices: map[str]Stats={};
    let empty: [domain.Market]=[];
    let pages: map[str][domain.Market]={};
    let data=Snapshot { markets:markets,categories:categories,sources:sources,stats:stats,seasons:seasons,generation:0,built_at:now,
        by_id:ids,by_slug:slugs,stats_by_market:prices,ordered_new:empty,ordered_ending:empty,ordered_trending:empty,pages:pages };
    index_snapshot(data);
    return data;
}

fn earlier(a: domain.Market,b: domain.Market,mode: str,stats: map[str]Stats) -> bool {
    if mode=="ending" && a.close_at!=b.close_at { return a.close_at<b.close_at; }
    if mode=="trending" {
        let av = -1; let bv = -1; let ap = -1; let bp = -1;
        if has(stats,a.id) { av=stats[a.id].volume_24h_units ?? -1; ap=stats[a.id].players ?? -1; }
        if has(stats,b.id) { bv=stats[b.id].volume_24h_units ?? -1; bp=stats[b.id].players ?? -1; }
        if av!=bv { return av>bv; }
        if ap!=bp { return ap>bp; }
    }
    if a.created_at!=b.created_at { return a.created_at>b.created_at; }
    return a.id>b.id;
}

fn sorted(rows: [domain.Market],mode: str,stats: map[str]Stats) -> [domain.Market] {
    let a: [domain.Market]=[]; let b: [domain.Market]=[];
    for row in rows { push(a,row); push(b,row); }
    let n=len(a); let width=1;
    while width<n {
        let low=0;
        while low<n {
            let mid=low+width; if mid>n { mid=n; }
            let high=low+2*width; if high>n { high=n; }
            let i=low; let j=mid; let out=low;
            while out<high {
                if i<mid && (j>=high || earlier(a[i],a[j],mode,stats)) { b[out]=a[i]; i+=1; }
                else { b[out]=a[j]; j+=1; }
                out+=1;
            }
            low=high;
        }
        let temporary=a; a=b; b=temporary;
        width*=2;
    }
    return a;
}

fn index_snapshot(s: Snapshot) {
    let published: [domain.Market]=[];
    for m in s.markets {
        s.by_id[m.id]=m; s.by_slug[m.slug]=m;
        if domain.public_status(m.status) { push(published,m); }
    }
    for stats in s.stats { s.stats_by_market[stats.market_id]=stats; }
    s.ordered_new=sorted(published,"new",s.stats_by_market);
    s.ordered_ending=sorted(published,"ending",s.stats_by_market);
    s.ordered_trending=sorted(published,"trending",s.stats_by_market);
    let categories=[""];
    for c in s.categories { push(categories,c.id); }
    for category in categories {
        for filter in ["new","trending","ending_soon"] {
            let rows=s.ordered_new;
            if filter=="trending" { rows=s.ordered_trending; }
            if filter=="ending_soon" { rows=s.ordered_ending; }
            for status in ["open","resolving","all"] { s.pages[category+":"+filter+":"+status]=filter_rows(rows,category,status,""); }
        }
    }
}

pub fn generation[C](s: Markets[C],wanted: int) -> result[Snapshot,Failed] {
    if wanted==0 { return snapshot(s); }
    mutex_lock(s.lock);
    let found: opt[Snapshot]=none;
    for item in s.history { if item.generation==wanted { found=some(item); break; } }
    mutex_unlock(s.lock);
    guard let data=found else { return err(failure("STALE_SNAPSHOT","")); }
    return ok(data);
}

pub fn public_market(data: Snapshot,selector: str) -> opt[domain.Market] {
    let found: opt[domain.Market]=none;
    if has(data.by_id,selector) { found=some(data.by_id[selector]); }
    else if has(data.by_slug,selector) { found=some(data.by_slug[selector]); }
    guard let m=found else { return none; }
    if !domain.public_status(m.status) { return none; }
    return some(m);
}

pub fn browse(data: Snapshot,category: str,filter: str,status: str,term: str) -> [domain.Market] {
    let key=category+":"+filter+":"+status;
    if len(term)==0 && has(data.pages,key) { return data.pages[key]; }
    let ordered=data.ordered_new;
    if filter=="ending_soon" { ordered=data.ordered_ending; }
    if filter=="trending" { ordered=data.ordered_trending; }
    return filter_rows(ordered,category,status,term);
}

fn filter_rows(ordered: [domain.Market],category: str,status: str,term: str) -> [domain.Market] {
    let out: [domain.Market]=[];
    for m in ordered {
        if len(category)>0 && m.category_id!=category { continue; }
        let open=m.status=="OPEN" || m.status=="SUSPENDED";
        if status=="open" && !open { continue; }
        if status=="resolving" && (open || m.status=="SETTLED") { continue; }
        if len(term)>0 && !strings.contains(strings.to_lower(m.question),strings.to_lower(term)) { continue; }
        push(out,m);
    }
    return out;
}

pub fn history[C](s: Markets[C],id: str,actor: str) -> result[str,Failed] {
    let read=s.store.history;
    return read(s.store.context,id,actor);
}

pub fn create_source[C](s: Markets[C],actor: str,name: str,url: str,kind: str) -> result[Source,Failed] {
    let write=s.store.source_create;
    return write(s.store.context,actor,name,url,kind,s.clock.now().unix_milli());
}

pub fn validate_fields[C](s: Markets[C],actor: str,p: domain.Patch) -> result[[domain.Problem],Failed] {
    let m=domain.patched(domain.draft("",actor,s.clock.now().unix_milli()),p);
    for id in [m.category_id,m.season_id,m.resolution_source_id] {
        if len(id)>0 && !uuid(id) { return err(failure("BAD_REQUEST","Invalid linked identifier.")); }
    }
    let validate=s.store.validate;
    return validate(s.store.context,m,true,s.clock.now().unix_milli());
}

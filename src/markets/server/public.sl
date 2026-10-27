import "http";
import "strings";
import "zokor";
import "../../platform/app" as app;
import "../domain" as domain;
import "../service" as markets;

fn optional_number(n: opt[int]) -> zokor.Json {
    if let value=n { return zokor.jint(value); }
    return zokor.jnull();
}

fn card(m: domain.Market,data: markets.Snapshot,now: int) -> zokor.Json {
    let category=zokor.jobj().set_str("id",m.category_id);
    for cat in data.categories {
        if cat.id==m.category_id { category.set_str("name",cat.name).set_str("icon",cat.icon); break; }
    }
    let status=m.status;
    let note=m.status_note;
    if (status=="OPEN" || status=="SUSPENDED") && now>=m.close_at { status="CLOSED"; note="Market closed"; }
    let j=zokor.jobj().set_str("id",m.id).set_str("slug",m.slug).set_str("question",m.question).set("category",category)
        .set_str("status",status).set("closes_at",at_json(m.close_at)).set_bool("closing_soon",m.close_at>now && m.close_at-now<10800000 && status=="OPEN")
        .set_int("redemption_units",m.redemption_units).set_str("status_note",note)
        .set("last_price",zokor.jnull()).set("chance_pct",zokor.jnull()).set("yes_ask",zokor.jnull())
        .set("no_ask",zokor.jnull()).set("volume_units",zokor.jnull()).set("change_24h",zokor.jnull());
    if has(data.stats_by_market,m.id) {
        let stats=data.stats_by_market[m.id];
        j.set("last_price",optional_number(stats.last_price)).set("yes_ask",optional_number(stats.yes_ask))
            .set("no_ask",optional_number(stats.no_ask)).set("volume_units",optional_number(stats.volume_units));
        if let last=stats.last_price { if m.redemption_units>0 { j.set_float("chance_pct",(last as float)*100.0/(m.redemption_units as float)); } }
        if let change=stats.change_24h { j.set_float("change_24h",to_float(change) ?? 0.0); }
    }
    return j;
}

fn detail_json(m: domain.Market,data: markets.Snapshot,now: int) -> zokor.Json {
    let j=card(m,data,now).set("rules",zokor.jobj().set_str("yes_if",m.yes_if).set_str("no_if",m.no_if).set_str("edge_cases",m.edge_cases))
        .set("resolve_by",at_json(m.resolve_by)).set("price_band",zokor.jobj().set_int("min",m.min_price).set_int("max",m.max_price).set_int("tick",m.tick))
        .set_int("max_order_qty",m.max_order_qty).set_int("fee_units",m.fee_units).set_int("terms_version",m.terms_version)
        .set_int("opening_price",m.opening_price).set("created_at",at_json(m.created_at));
    for source in data.sources {
        if source.id==m.resolution_source_id { j.set("resolution_source",zokor.jobj().set_str("name",source.name).set_str("url",source.url_pattern)); break; }
    }
    for season in data.seasons {
        if season.id==m.season_id { j.set("season",zokor.jobj().set_int("ordinal",season.ordinal).set("ends_at",at_json(season.ends_at))); break; }
    }
    return j;
}

fn categories(c: zokor.Ctx[app.App]) -> http.Response {
    let r=markets.snapshot(c.state.markets);
    guard let data=r else let f=err_of(r) { return failure(c,f); }
    let counts: map[str]int={};
    for m in data.ordered_new {
        if m.status=="OPEN" && m.close_at>c.state.markets.clock.now().unix_milli() { let count=0; if has(counts,m.category_id) { count=counts[m.category_id]; } counts[m.category_id]=count+1; }
    }
    let items=zokor.jarr();
    for cat in data.categories {
        let count=0; if has(counts,cat.id) { count=counts[cat.id]; }
        items.add(zokor.jobj().set_str("id",cat.id).set_str("name",cat.name).set_str("icon",cat.icon).set_int("open_count",count));
    }
    return zokor.ok_json(items.render());
}

fn public_list(c: zokor.Ctx[app.App]) -> http.Response {
    let filter=c.query("filter"); if len(filter)==0 { filter="new"; }
    let status=c.query("status"); if len(status)==0 { status="open"; }
    let category=c.query("category");
    let limit=c.query_int("limit",24);
    if (filter!="new" && filter!="trending" && filter!="ending_soon") || (status!="open" && status!="resolving" && status!="all") || limit<1 || limit>100 {
        return zokor.respond(c.errors,"BAD_REQUEST",c.request_id);
    }
    let wanted=0; let skip=0;
    if len(c.query("cursor"))>0 {
        let cr=zokor.decode_cursor(c.query("cursor"));
        guard let values=cr else { return zokor.respond(c.errors,"BAD_REQUEST",c.request_id); }
        if len(values)!=5 || values[1]!=category || values[2]!=filter || values[3]!=status { return zokor.respond(c.errors,"BAD_REQUEST",c.request_id); }
        wanted=to_int(values[0]) ?? -1; skip=to_int(values[4]) ?? -1;
        if wanted<1 || skip<0 { return zokor.respond(c.errors,"BAD_REQUEST",c.request_id); }
    }
    let sr=markets.generation(c.state.markets,wanted);
    guard let data=sr else let f=err_of(sr) { return failure(c,f); }
    let rows=markets.browse(data,category,filter,status,"");
    let items=zokor.jarr();
    let index=skip;
    let now=c.state.markets.clock.now().unix_milli();
    while index<len(rows) && items.size()<limit { items.add(card(rows[index],data,now)); index+=1; }
    let body=zokor.jobj().set("items",items).set("next_cursor",zokor.jnull()).set_int("generation",data.generation).set("as_of",at_json(data.built_at));
    if index<len(rows) { body.set_str("next_cursor",zokor.encode_cursor([to_str(data.generation),category,filter,status,to_str(index)])); }
    return zokor.ok_json(body.render());
}

fn detail(c: zokor.Ctx[app.App]) -> http.Response {
    let r=markets.snapshot(c.state.markets);
    guard let data=r else let f=err_of(r) { return failure(c,f); }
    guard let m=markets.public_market(data,c.param("selector")) else { return zokor.respond(c.errors,"NOT_FOUND",c.request_id); }
    return zokor.ok_json(detail_json(m,data,c.state.markets.clock.now().unix_milli()).render());
}

fn featured(c: zokor.Ctx[app.App]) -> http.Response {
    let r=markets.snapshot(c.state.markets);
    guard let data=r else let f=err_of(r) { return failure(c,f); }
    let selected: opt[domain.Market]=none;
    for m in data.ordered_new {
        if m.status!="OPEN" || m.close_at<=c.state.markets.clock.now().unix_milli() { continue; }
        if let current=selected {
            if m.featured_rank>0 && (current.featured_rank==0 || m.featured_rank<current.featured_rank) { selected=some(m); }
        } else { selected=some(m); }
    }
    guard let m=selected else { return zokor.respond(c.errors,"NOT_FOUND",c.request_id); }
    return zokor.ok_json(card(m,data,c.state.markets.clock.now().unix_milli()).set("series_7d",zokor.jnull()).render());
}

fn search(c: zokor.Ctx[app.App]) -> http.Response {
    let term=strings.trim(c.query("q"));
    if domain.unicode_length(term)<2 || domain.unicode_length(term)>140 { return zokor.respond(c.errors,"BAD_REQUEST",c.request_id); }
    let r=markets.snapshot(c.state.markets);
    guard let data=r else let f=err_of(r) { return failure(c,f); }
    let items=zokor.jarr();
    for m in markets.browse(data,"","new","all",term) {
        items.add(card(m,data,c.state.markets.clock.now().unix_milli()));
        if items.size()==50 { break; }
    }
    return zokor.ok_json(items.render());
}

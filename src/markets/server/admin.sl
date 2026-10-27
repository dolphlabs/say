import "http";
import "zokor";
import "../../platform/app" as app;
import "../domain" as domain;
import "../service" as markets;

fn caller(c: zokor.Ctx[app.App]) -> result[domain.Actor,http.Response] {
    let r=app.market_roles(c.state,c.local("account_id"));
    guard let roles=r else { return err(zokor.respond(c.errors,"UNAVAILABLE",c.request_id)); }
    let a=domain.Actor { id:c.local("account_id"),roles:roles };
    if !domain.reviewer(a) && !domain.has_role(a,"creator") { return err(zokor.respond(c.errors,"FORBIDDEN_ROLE",c.request_id)); }
    return ok(a);
}

fn admin_list(c: zokor.Ctx[app.App]) -> http.Response {
    let ar=caller(c);
    guard let a=ar else let bad=err_of(ar) { return bad; }
    let sr=markets.snapshot(c.state.markets);
    guard let s=sr else let f=err_of(sr) { return failure(c,f); }
    let limit=c.query_int("limit",50);
    let skip=0;
    let cursor=c.query("cursor");
    if len(cursor)>0 {
        let cr=zokor.decode_cursor(cursor);
        guard let parts=cr else { return zokor.respond(c.errors,"BAD_REQUEST",c.request_id); }
        if len(parts)!=5 || parts[0]!=to_str(s.generation) || parts[1]!=c.query("status") || parts[2]!=c.query("mine") || parts[3]!=a.id { return zokor.respond(c.errors,"STALE_SNAPSHOT",c.request_id); }
        skip=to_int(parts[4]) ?? -1;
    }
    if skip<0 || limit<1 || limit>100 { return zokor.respond(c.errors,"BAD_REQUEST",c.request_id); }
    let items=zokor.jarr();
    let seen=0;
    let more=false;
    for m in s.markets {
        if domain.authorize(a,"read",m)!="" || (c.query("mine")=="true" && m.created_by!=a.id) { continue; }
        if len(c.query("status"))>0 && c.query("status")!=m.status { continue; }
        if seen<skip { seen+=1; continue; }
        if items.size()==limit { more=true; break; }
        items.add(market_json(m));
        seen+=1;
    }
    let body=zokor.jobj().set("items",items).set("next_cursor",zokor.jnull()).set_int("generation",s.generation);
    if more { body.set_str("next_cursor",zokor.encode_cursor([to_str(s.generation),c.query("status"),c.query("mine"),a.id,to_str(seen)])); }
    return zokor.no_store(zokor.ok_json(body.render()));
}

fn market_history(c: zokor.Ctx[app.App]) -> http.Response {
    let s=c.state.markets;
    let r=markets.history(s,c.param("id"),c.local("account_id"));
    guard let body=r else let f=err_of(r) { return failure(c,f); }
    return zokor.no_store(zokor.ok_json(body));
}

fn validate_market(c: zokor.Ctx[app.App]) -> http.Response {
    let ar=caller(c);
    guard let _a=ar else let bad=err_of(ar) { return bad; }
    let dr: result[Input,http.Response]=zokor.dto(c);
    guard let body=dr else let bad=err_of(dr) { return bad; }
    let jr=c.json_body();
    guard let raw=jr else { return zokor.respond(c.errors,"BAD_REQUEST",c.request_id); }
    let pr=patch_of(body,raw);
    guard let p=pr else let field=err_of(pr) { return zokor.respond_fields(c.errors,"BAD_REQUEST",[zokor.field(field,"Use an RFC3339 timestamp.")],c.request_id); }
    let s=c.state.markets;
    let r=markets.validate_fields(s,c.local("account_id"),p);
    guard let issues=r else let f=err_of(r) { return failure(c,f); }
    let list=zokor.jarr();
    for p in issues { list.add(zokor.jobj().set_str("code",p.code).set_str("field",p.field).set_str("message",p.message)); }
    return zokor.no_store(zokor.ok_json(zokor.jobj().set_bool("valid",len(issues)==0).set("errors",list).render()));
}

fn source_list(c: zokor.Ctx[app.App]) -> http.Response {
    let ar=caller(c);
    guard let _a=ar else let bad=err_of(ar) { return bad; }
    let sr=markets.snapshot(c.state.markets);
    guard let s=sr else let f=err_of(sr) { return failure(c,f); }
    let items=zokor.jarr();
    for source in s.sources {
        items.add(zokor.jobj().set_str("id",source.id).set_str("name",source.name).set_str("url_pattern",source.url_pattern)
            .set_str("kind",source.kind).set_bool("approved",source.approved));
    }
    return zokor.no_store(zokor.ok_json(items.render()));
}

fn source_create(c: zokor.Ctx[app.App]) -> http.Response {
    let dr: result[SourceDto,http.Response]=zokor.dto(c);
    guard let body=dr else let bad=err_of(dr) { return bad; }
    let s=c.state.markets;
    let r=markets.create_source(s,c.local("account_id"),body.name,body.url_pattern,body.kind);
    guard let source=r else let f=err_of(r) { return failure(c,f); }
    return zokor.created(zokor.jobj().set_str("id",source.id).set_str("name",source.name).set_bool("approved",false).render(),"/v1/admin/resolution-sources/"+source.id);
}

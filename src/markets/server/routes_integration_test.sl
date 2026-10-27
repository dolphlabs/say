import "crypto";
import "encoding";
import "http";
import "proc";
import "time";
import "timez";
import "zokor";
import "../../platform/app" as app;
import "../../platform/cache" as cache;
import "../../platform/config" as config;
import "../../platform/db" as db;
import "../../platform/email" as email;
import "../../platform/web" as web;
import "../service" as markets;

gc struct HttpRig { router: zokor.Router[app.App], state: app.App, owner: db.Db }
gc struct Player { id: str, cookie: str }

fn text_query(database: db.Db,sql: str,args: [str]) -> str {
    let r=db.one_text(database,sql,args,until_of(time.mono()+30000000000));
    guard let value=r else let e=err_of(r) { panic(e); }
    return value;
}

fn http_rig() -> opt[HttpRig] {
    let owner_url=proc.getenv("TEST_DATABASE_URL") ?? "";
    let app_url=proc.getenv("TEST_APP_DATABASE_URL") ?? "";
    if len(owner_url)==0 || len(app_url)==0 { println("skip registry HTTP integration (test URLs not set)"); return none; }
    let cfg: map[str]str={}; cfg["PORT"]="8080"; cfg["DATABASE_URL"]=owner_url;
    cfg["OTP_SECRET"]="registry-http-secret-0123456789abcdef";
    let opened=db.open(zokor.config_from_values(cfg)); guard let owner=opened else { panic("owner"); }
    let loaded=zokor.load_migrations("migrations",zokor.migration_limits()); guard let files=loaded else { panic("migrations"); }
    let migrated=zokor.migrate(owner.pool,files,until_of(time.mono()+30000000000));
    guard let migrated_count=migrated else let e=err_of(migrated) { panic(e); }
    cfg["DATABASE_URL"]=app_url;
    let settings=config.settings_from(zokor.config_from_values(cfg));
    let opened_app=db.open(zokor.config_from_values(cfg)); guard let d=opened_app else { panic("app"); }
    let built=app.for_tests(settings,d,cache.in_memory(),email.in_memory());
    guard let state=built else let e=err_of(built) { panic(e); }
    let tick=state.ledger.store.tick;
    let stepped=tick(state.ledger.store.context,state.ledger.clock.now(),settings.ledger.season_anchor);
    guard let season_steps=stepped else let e=err_of(stepped) { panic(e); }
    let warmed=markets.refresh(state.markets); guard let initial_generation=warmed else let f=err_of(warmed) { panic(f); }
    let router=zokor.new_router(state); web.register_common(router.errors); mount(router);
    return some(HttpRig { router:router,state:state,owner:owner });
}

fn player(r: HttpRig,role: str) -> Player {
    let rb=crypto.rand(7); guard let random=rb else { panic("rand"); }
    let name="m"+encoding.hex_encode(random);
    let id=text_query(r.owner,"insert into accounts(username,status,email_verified_at) values($1,'ACTIVE',now()) returning id::text as t",[name]);
    let _role=text_query(r.owner,"insert into account_roles(account_id,role) values($1::uuid,$2) returning role as t",[id,role]);
    let token=name+"-test-session-token-0123456789abcdef";
    let _session=text_query(r.owner,"insert into sessions(account_id,token_hash,expires_at) values($1::uuid,decode($2,'hex'),now()+interval '1 hour') returning id::text as t",
        [id,encoding.hex_encode(crypto.sha256(to_bytes(token)))]);
    return Player { id:id,cookie:"say_session="+token };
}

fn req(r: HttpRig,method: zokor.Method,path: str,body: str,cookie: str) -> http.Response {
    let request=zokor.request(method,path);
    if len(body)>0 { request=request.json_body(body); }
    if len(cookie)>0 { request=request.header("cookie",cookie); }
    return r.router.serve(request.build());
}

fn db_close_http(r: HttpRig, database: db.Db) {
    db.close(r.owner);
    db.close(database);
}

fn test_http_session_roles_lifecycle_and_public_snapshot() {
    guard let r=http_rig() else { return; }
    let author=player(r,"creator"); let approver=player(r,"curator"); let stranger=player(r,"creator");
    let denied=req(r,zokor.Method.POST,"/v1/admin/markets","{}","");
    assert(zokor.resp_status(denied)==401,zokor.resp_text(denied));
    assert(zokor.resp_status(req(r,zokor.Method.GET,"/v1/admin/seasons","",""))==401);
    let choices=req(r,zokor.Method.GET,"/v1/admin/seasons","",author.cookie);
    assert(zokor.resp_status(choices)==200,zokor.resp_text(choices));
    let season_items=zokor.resp_json(choices).get("items");
    assert(season_items.size()>0);
    for i in 0..season_items.size() {
        let item=season_items.at(i); let status=item.get("status").str_or("");
        assert((status=="ACTIVE" || status=="SCHEDULED") && len(item.get("timezone").str_or(""))>0);
    }
    let season=text_query(r.owner,"select id::text as t from seasons where status='ACTIVE'",[]);
    let source=text_query(r.owner,"insert into resolution_sources(name,url_pattern,kind,approved,created_by,approved_by,approved_at) " +
        "values('HTTP test source','https://fixture.test/results','html',true,$1::uuid,$2::uuid,now()) returning id::text as t",
        [author.id,approver.id]);
    let now=r.state.markets.clock.now();
    let body=zokor.jobj().set_str("question","Will Enyimba win the Sunday fixture?")
        .set_str("category_id","00000000-0000-4000-a000-000000000101").set_str("season_id",season).set_str("resolution_source_id",source)
        .set("rules",zokor.jobj().set_str("yes_if","The official final result is an Enyimba victory.")
            .set_str("no_if","The official final result is not an Enyimba victory.").set_str("edge_cases","Postponement or cancellation is reviewed for void."))
        .set_str("open_at",now.rfc3339_milli()).set_str("close_at",now.add(7200000000000).rfc3339_milli())
        .set_str("resolve_by",now.add(14400000000000).rfc3339_milli()).set_int("redemption_units",100);
    let created=req(r,zokor.Method.POST,"/v1/admin/markets",body.render(),author.cookie);
    assert(zokor.resp_status(created)==201,zokor.resp_text(created));
    let id=zokor.resp_json(created).get("id").str_or("");
    let refreshed=markets.refresh(r.state.markets); guard let refreshed_generation=refreshed else { panic("refresh"); }
    let extra=req(r,zokor.Method.POST,"/v1/admin/markets","{}",author.cookie);
    assert(zokor.resp_status(extra)==201,zokor.resp_text(extra));
    let again=markets.refresh(r.state.markets); guard let again_generation=again else { panic("refresh"); }
    let page=req(r,zokor.Method.GET,"/v1/admin/markets?limit=1&mine=true","",author.cookie);
    let cursor=zokor.resp_json(page).get("next_cursor").str_or(""); assert(len(cursor)>0);
    assert(zokor.resp_status(req(r,zokor.Method.GET,"/v1/admin/markets?limit=1&mine=false&cursor="+cursor,"",author.cookie))==409);
    assert(zokor.resp_status(req(r,zokor.Method.GET,"/v1/admin/markets?limit=1&mine=true&cursor="+cursor,"",stranger.cookie))==409);
    let drafts=req(r,zokor.Method.GET,"/v1/admin/markets","",stranger.cookie);
    assert(zokor.resp_status(drafts)==200 && zokor.resp_json(drafts).get("items").size()==0,zokor.resp_text(drafts));
    assert(zokor.resp_status(req(r,zokor.Method.GET,"/v1/markets/"+id,"",""))==404);
    let submitted=req(r,zokor.Method.POST,"/v1/admin/markets/"+id+"/submit","{\"version\":1}",author.cookie);
    assert(zokor.resp_status(submitted)==200,zokor.resp_text(submitted));
    let approved=req(r,zokor.Method.POST,"/v1/admin/markets/"+id+"/approve","{\"version\":2}",approver.cookie);
    assert(zokor.resp_status(approved)==200,zokor.resp_text(approved));
    let found=markets.get(r.state.markets,id,approver.id); guard let m=found else { panic("approved"); }
    assert(markets.advance_batch(r.state.markets,[m],r.state.markets.clock.now().unix_milli()));
    let funding=markets.get(r.state.markets,id,approver.id); guard let funded=funding else { panic("funding"); }
    assert(markets.advance_batch(r.state.markets,[funded],r.state.markets.clock.now().unix_milli()));
    let warmed=markets.refresh(r.state.markets); guard let warmed_generation=warmed else { panic("warm"); }
    let public_=req(r,zokor.Method.GET,"/v1/markets/"+id,"","");
    assert(zokor.resp_status(public_)==200,zokor.resp_text(public_));
    assert(zokor.resp_json(public_).get("last_price").is_null());
    assert(!zokor.resp_json(public_).has_key("created_by"));
    let list=req(r,zokor.Method.GET,"/v1/markets?filter=trending&status=open","","");
    assert(zokor.resp_status(list)==200 && zokor.resp_json(list).get("items").size()>0,zokor.resp_text(list));
    let stale=req(r,zokor.Method.PATCH,"/v1/admin/markets/"+id,"{\"version\":1,\"question\":\"Will the edited question be refused?\"}",author.cookie);
    assert(zokor.resp_status(stale)==409,zokor.resp_text(stale));
    db.close(r.owner);
    guard let app_db=r.state.db else { panic("db"); }
    db.close(app_db);
}

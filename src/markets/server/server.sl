import "http";
import "strings";
import "timez";
import "zokor";
import "../../platform/app" as app;
import "../../platform/auth" as auth;
import "../domain" as domain;
import "../service" as markets;

pub fn mount(r: zokor.Router[app.App]) -> int {
    register_errors(r.errors);
    let g=r.group("/v1/admin/markets");
    g.before(auth.require_session);
    g.post("",create_market);
    g.get("",admin_list);
    g.patch("/:id",edit_market);
    g.post("/:id/submit",submit_market);
    g.post("/:id/approve",approve_market);
    g.post("/:id/request-changes",request_changes);
    g.post("/:id/reject",reject_market);
    g.post("/:id/suspend",suspend_market);
    g.post("/:id/resume",resume_market);
    g.post("/:id/clarify",clarify_market);
    g.get("/:id/history",market_history);
    g.post("/validate",validate_market);
    // zokor:routes
    let seasons=r.group("/v1/admin/seasons");
    seasons.before(auth.require_session);
    seasons.get("",season_choices);
    let sources=r.group("/v1/admin/resolution-sources");
    sources.before(auth.require_session);
    sources.get("",source_list); sources.post("",source_create);
    // zokor:public
    r.get("/v1/categories",categories);
    r.get("/v1/markets",public_list);
    r.get("/v1/markets/featured",featured);
    r.get("/v1/markets/search",search);
    r.get("/v1/markets/:selector",detail);
    return 0;
}

fn command(c: zokor.Ctx[app.App],action: str) -> http.Response {
    let dr: result[Input,http.Response]=zokor.dto(c);
    guard let body=dr else let bad=err_of(dr) { return bad; }
    let jr=c.json_body();
    guard let raw=jr else { return zokor.respond(c.errors,"BAD_REQUEST",c.request_id); }
    if action=="clarify" {
        for key in raw.keys_of() {
            if key!="version" && key!="reason" && key!="question" && key!="rules" { return zokor.respond(c.errors,"LOCKED_AFTER_OPEN",c.request_id); }
        }
    }
    let pr=patch_of(body,raw);
    guard let patch=pr else let field=err_of(pr) {
        return zokor.respond_fields(c.errors,"BAD_REQUEST",[zokor.field(field,"Use an RFC3339 timestamp.")],c.request_id);
    }
    let r=markets.mutate(c.state.markets,c.local("account_id"),action,c.param("id"),body.version ?? 0,patch,body.reason ?? "");
    guard let m=r else let f=err_of(r) { return failure(c,f); }
    if action=="create" { return zokor.created(market_json(m).render(),"/v1/admin/markets/"+m.id); }
    return zokor.no_store(zokor.ok_json(market_json(m).render()));
}

fn create_market(c: zokor.Ctx[app.App]) -> http.Response { return command(c,"create"); }

fn edit_market(c: zokor.Ctx[app.App]) -> http.Response { return command(c,"edit"); }

fn submit_market(c: zokor.Ctx[app.App]) -> http.Response { return command(c,"submit"); }

fn approve_market(c: zokor.Ctx[app.App]) -> http.Response { return command(c,"approve"); }

fn request_changes(c: zokor.Ctx[app.App]) -> http.Response { return command(c,"request-changes"); }

fn reject_market(c: zokor.Ctx[app.App]) -> http.Response { return command(c,"reject"); }

fn suspend_market(c: zokor.Ctx[app.App]) -> http.Response { return command(c,"suspend"); }

fn resume_market(c: zokor.Ctx[app.App]) -> http.Response { return command(c,"resume"); }

fn clarify_market(c: zokor.Ctx[app.App]) -> http.Response { return command(c,"clarify"); }

fn season_choices(c: zokor.Ctx[app.App]) -> http.Response {
    let actor=caller(c); guard let _actor=actor else let response=err_of(actor) { return response; }
    let loaded=markets.snapshot(c.state.markets); guard let data=loaded else let f=err_of(loaded) { return failure(c,f); }
    let items=zokor.jarr();
    for season in data.seasons {
        if season.status!="ACTIVE" && season.status!="SCHEDULED" { continue; }
        items.add(zokor.jobj().set_str("id",season.id).set_int("ordinal",season.ordinal).set_str("status",season.status)
            .set("starts_at",at_json(season.starts_at)).set("ends_at",at_json(season.ends_at)).set_str("timezone",c.state.settings.timezone));
    }
    return zokor.no_store(zokor.ok_json(zokor.jobj().set("items",items).render()));
}

import "http";
import "zokor";
import "../../platform/app" as app;
import "../service" as markets;

fn register_errors(r: zokor.Registry) {
    for code in ["CLOSE_AFTER_SEASON_END","RESOLVE_BY_INVALID","PAYOUT_INVALID","PRICE_RANGE_INVALID",
        "BAND_NOT_SYMMETRIC","TICK_INVALID","RULES_INCOMPLETE","QUESTION_INVALID","SOURCE_NOT_APPROVED","SEASON_NOT_OPEN"] {
        zokor.register(r,code,422,"Check the market fields.");
    }
    zokor.register(r,"SELF_APPROVAL_FORBIDDEN",403,"Someone else must approve this request.");
    zokor.register(r,"STALE_VERSION",409,"This market changed. Reload it first.");
    zokor.register(r,"STALE_APPROVAL",409,"This approval no longer matches the request.");
    zokor.register(r,"STALE_SNAPSHOT",409,"This page expired. Start from the first page.");
    zokor.register(r,"INVALID_TRANSITION",409,"That action is not available in this state.");
    zokor.register(r,"FORBIDDEN_ROLE",403,"Your role does not allow this action.");
    zokor.register(r,"LOCKED_AFTER_OPEN",409,"An opened market's economics cannot change.");
}

fn failure(c: zokor.Ctx[app.App],f: markets.Failed) -> http.Response {
    let code="UNAVAILABLE";
    for allowed in ["BAD_REQUEST","NOT_FOUND","UNAVAILABLE","SELF_APPROVAL_FORBIDDEN","STALE_VERSION","STALE_APPROVAL",
        "STALE_SNAPSHOT","INVALID_TRANSITION","FORBIDDEN_ROLE","LOCKED_AFTER_OPEN"] {
        if f.code==allowed { code=f.code; break; }
    }
    let fields: [zokor.FieldError]=[];
    for p in f.problems {
        push(fields,zokor.field("__validation",zokor.jobj().set_str("code",p.code).set_str("field",p.field).set_str("message",p.message).render()));
    }
    if code=="UNAVAILABLE" {
        c.state.settings.server.logger.error("markets",f.detail);
    } else if code=="BAD_REQUEST" && len(f.detail)>0 && len(fields)==0 {
        push(fields,zokor.field("request",f.detail));
    }
    return zokor.respond_fields(c.errors,code,fields,c.request_id);
}

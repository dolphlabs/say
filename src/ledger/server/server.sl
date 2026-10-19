// zokor:public
import "http";
import "zokor";
import "../../platform/app" as app;
import "../service" as ledger;

// The season clock is public: the signup screens show it before login.
pub fn mount(r: zokor.Router[app.App]) -> int {
    let g = r.group("/v1/seasons");
    g.get("/current", current);
    return 0;
}

fn current(c: zokor.Ctx[app.App]) -> http.Response {
    let r = ledger.current_season(c.state.ledger);
    guard let found = r else let e = err_of(r) {
        c.state.settings.server.logger.error("ledger", "current season: " + e);
        return zokor.respond(c.errors, "UNAVAILABLE", c.request_id);
    }
    guard let s = found else {
        return zokor.ok_json(zokor.jobj().set("season", zokor.jnull()).render());
    }
    let season = zokor.jobj()
        .set_int("ordinal", s.ordinal)
        .set_str("starts_at", s.starts_at.rfc3339())
        .set_str("ends_at", s.ends_at.rfc3339())
        .set_str("status", s.status);
    return zokor.cache_for(zokor.ok_json(zokor.jobj().set("season", season).render()), 30);
}

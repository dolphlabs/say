// zokor:public
import "http";
import "time";
import "zokor";
import "../../platform/app" as app;
import "../domain" as domain;
import "../service" as profile_svc;

pub fn mount(r: zokor.Router[app.App]) -> int {
    register_errors(r.errors);

    r.get("/v1/users/:username", get_user_profile_handler);

    return 0;
}

fn register_errors(e: zokor.ErrorRegistry) {
    zokor.register_error(e, "profiles.not_found", 404, "NOT_FOUND", "User profile not found or deleted.");
    zokor.register_error(e, "profiles.unavailable", 503, "UNAVAILABLE", "Profile service temporarily unavailable.");
}

fn call_to_json(c: domain.CallItem) -> zokor.JObj {
    let market_obj = zokor.jobj()
        .set_str("slug", c.market.slug)
        .set_str("question", c.market.question);

    let obj = zokor.jobj()
        .set_obj("market", market_obj)
        .set_str("side", c.side)
        .set_str("status", c.status);

    if let ch = c.chance_pct {
        obj.set_int("chance_pct", ch);
    }
    return obj;
}

fn stats_to_json(s: domain.CurrentSeasonStats) -> zokor.JObj {
    return zokor.jobj()
        .set_int("rank", s.rank)
        .set_int("of", s.of)
        .set_int("profit", s.profit)
        .set_int("calls", s.calls)
        .set_int("right", s.right)
        .set_int("settled", s.settled);
}

fn profile_to_json(p: domain.Profile) -> zokor.JObj {
    let calls_arr = zokor.jarr();
    for c in p.calls {
        calls_arr.add_obj(call_to_json(c));
    }

    return zokor.jobj()
        .set_str("username", p.username)
        .set_str("avatar_color", p.avatar_color)
        .set_str("joined_season", p.joined_season)
        .set_str("share_url", p.share_url)
        .set_obj("current_season", stats_to_json(p.current_season))
        .set_arr("calls", calls_arr);
}

fn get_user_profile_handler(c: zokor.Ctx[app.App]) -> http.Response {
    let username = c.param("username");
    let now_ms = (time.mono() / 1000000) as int;
    let base_url = c.state.settings.server.base_url;

    let res = profile_svc.get_profile(c.state.profiles, username, base_url, now_ms);
    guard let outcome = res else let e = err_of(res) {
        c.state.settings.server.logger.warn("profiles", "get_profile: " + e);
        return zokor.respond(c.errors, "profiles.unavailable", c.request_id);
    }

    if outcome.status == "NOT_FOUND" {
        return zokor.respond(c.errors, "profiles.not_found", c.request_id);
    }

    if outcome.status == "REDIRECT" {
        let resp = zokor.redirect("/v1/users/" + outcome.redirect_username, 301);
        resp.headers["Cache-Control"] = "public, max-age=10";
        return resp;
    }

    guard let prof = outcome.profile else {
        return zokor.respond(c.errors, "profiles.not_found", c.request_id);
    }

    let body = profile_to_json(prof).render();
    let resp = zokor.ok_json(body);
    resp.headers["Cache-Control"] = "public, max-age=10";
    return resp;
}

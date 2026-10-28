// zokor:public
import "http";
import "strconv";
import "zokor";
import "../../platform/app" as app;
import "../../platform/auth" as auth;
import "../domain" as domain;
import "../service" as standings_svc;

pub fn mount(r: zokor.Router[app.App]) -> int {
    register_errors(r.errors);

    r.get("/v1/leaderboard", get_leaderboard_handler);
    r.get("/v1/leaderboard/strip", get_strip_handler);

    return 0;
}

fn register_errors(e: zokor.ErrorRegistry) {
    zokor.register_error(e, "standings.unavailable", 503, "UNAVAILABLE", "Standings service is currently warming up or unavailable.");
}

fn row_to_json(r: domain.StandingsRow) -> zokor.JObj {
    let obj = zokor.jobj()
        .set_int("rank", r.rank_profit)
        .set_str("account_id", r.account_id)
        .set_str("username", r.username)
        .set_str("avatar_color", r.avatar_color)
        .set_int("calls", r.calls)
        .set_str("win_rate", r.win_rate)
        .set_int("profit", r.profit);
    if let rw = r.rank_win {
        obj.set_int("rank_win", rw);
    }
    return obj;
}

fn season_to_json(s: domain.SeasonInfo) -> zokor.JObj {
    let obj = zokor.jobj()
        .set_int("ordinal", s.ordinal)
        .set_str("status", s.status)
        .set_int("starts_at", s.starts_at)
        .set_int("ends_at", s.ends_at)
        .set_int("players", s.players)
        .set_bool("provisional", s.provisional);
    if s.provisional {
        obj.set_str("provisional_reason", s.provisional_reason);
    }
    return obj;
}

fn get_leaderboard_handler(c: zokor.Ctx[app.App]) -> http.Response {
    let sort = c.query("sort");
    if sort == "" { sort = "profit"; }
    let limit_str = c.query("limit");
    let limit = 50;
    if limit_str != "" {
        limit = to_int(limit_str) ?? 50;
    }
    let cursor = c.query("cursor");
    let caller_id = c.local("account_id");

    let res = standings_svc.get_leaderboard(c.state.standings, sort, limit, cursor, caller_id);
    guard let page = res else let e = err_of(res) {
        c.state.settings.server.logger.warn("standings", "get_leaderboard: " + e);
        return zokor.respond(c.errors, "standings.unavailable", c.request_id);
    }

    let podium_arr = zokor.jarr();
    for p in page.podium {
        podium_arr.add_obj(row_to_json(p));
    }

    let items_arr = zokor.jarr();
    for item in page.items {
        items_arr.add_obj(row_to_json(item));
    }

    let out = zokor.jobj()
        .set_obj("season", season_to_json(page.season))
        .set_arr("podium", podium_arr)
        .set_arr("items", items_arr)
        .set_str("next_cursor", page.next_cursor);

    if let me = page.me {
        let me_obj = zokor.jobj()
            .set_int("rank", me.rank)
            .set_int("of", me.of)
            .set_int("profit", me.profit)
            .set_str("percentile_label", me.percentile_label)
            .set_obj("row", row_to_json(me.row));
        if let top20 = me.to_top20 {
            me_obj.set_int("to_top20", top20);
        } else {
            me_obj.set_null("to_top20");
        }
        out.set_obj("me", me_obj);
    }

    return zokor.no_store(zokor.ok_json(out.render()));
}

fn get_strip_handler(c: zokor.Ctx[app.App]) -> http.Response {
    let res = standings_svc.get_strip(c.state.standings);
    guard let strip = res else let e = err_of(res) {
        c.state.settings.server.logger.warn("standings", "get_strip: " + e);
        return zokor.respond(c.errors, "standings.unavailable", c.request_id);
    }

    let items_arr = zokor.jarr();
    for item in strip {
        items_arr.add_obj(row_to_json(item));
    }

    let out = zokor.jobj().set_arr("items", items_arr);
    return zokor.no_store(zokor.ok_json(out.render()));
}

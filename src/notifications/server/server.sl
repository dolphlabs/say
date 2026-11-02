// zokor:public
import "http";
import "time";
import "zokor";
import "../../platform/app" as app;
import "../../platform/auth" as auth;
import "../domain" as domain;
import "../service" as notif_svc;

pub fn mount(r: zokor.Router[app.App]) -> int {
    zokor.register(r.errors, "BAD_REQUEST", 400, "Check your request parameters.");
    zokor.register(r.errors, "INVALID_TOKEN", 400, "The unsubscribe token is invalid.");
    zokor.register(r.errors, "TOKEN_EXPIRED", 400, "The unsubscribe token has expired.");
    zokor.register(r.errors, "UNAVAILABLE", 503, "Service temporarily unavailable.");

    let me = r.group("/v1/me");
    me.before(auth.require_session);
    me.get("/notifications", get_notifications_handler);
    me.post("/notifications/read", post_mark_read_handler);
    me.get("/notification-prefs", get_prefs_handler);
    me.put("/notification-prefs", put_pref_handler);

    // Public unsubscribe route
    r.get("/v1/unsubscribe", get_unsubscribe_handler);
    return 0;
}

fn item_json(n: domain.NotificationItem) -> zokor.Json {
    return zokor.jobj()
        .set_str("id", n.id)
        .set_str("kind", n.kind)
        .set_str("title", n.title)
        .set_str("body", n.body)
        .set_str("link", n.link_url)
        .set_str("created_at", n.created_at)
        .set_str("updated_at", n.updated_at)
        .set_bool("unread", n.unread);
}

fn pref_json(p: domain.NotificationPref) -> zokor.Json {
    return zokor.jobj()
        .set_str("kind", p.kind)
        .set_str("label", p.label)
        .set_str("hint", p.hint)
        .set_bool("in_app", p.in_app)
        .set_bool("email", p.email);
}

fn get_notifications_handler(c: zokor.Ctx[app.App]) -> http.Response {
    let account_id = c.local("account_id");
    let cursor = c.query("cursor");
    let limit = c.query_int("limit", 20);

    let r = notif_svc.get_notifications(c.state.notifications, account_id, cursor, limit);
    guard let page = r else let e = err_of(r) {
        return zokor.respond(c.errors, "UNAVAILABLE", c.request_id);
    }

    let items_arr = zokor.jarr();
    for it in page.items {
        items_arr.add(item_json(it));
    }

    let body = zokor.jobj()
        .set("items", items_arr)
        .set_int("unread_count", page.unread_count);

    if len(page.next_cursor) > 0 {
        body.set_str("next_cursor", page.next_cursor);
    } else {
        body.set("next_cursor", zokor.jnull());
    }

    return zokor.no_store(zokor.ok_json(body.render()));
}

fn post_mark_read_handler(c: zokor.Ctx[app.App]) -> http.Response {
    let account_id = c.local("account_id");
    let dr: result[ReadNotifDto, http.Response] = zokor.dto(c);
    guard let body = dr else let bad = err_of(dr) {
        return bad;
    }

    let mark_all = false;
    if let a = body.all {
        mark_all = a;
    }

    let ids: [str] = [];
    if let opt_ids = body.ids {
        ids = opt_ids;
    }

    let r = notif_svc.mark_read(c.state.notifications, account_id, ids, mark_all);
    guard let _ = r else let e = err_of(r) {
        return zokor.respond(c.errors, "UNAVAILABLE", c.request_id);
    }

    return zokor.no_store(zokor.no_content());
}

fn get_prefs_handler(c: zokor.Ctx[app.App]) -> http.Response {
    let account_id = c.local("account_id");
    let r = notif_svc.get_prefs(c.state.notifications, account_id);
    guard let prefs = r else let e = err_of(r) {
        return zokor.respond(c.errors, "UNAVAILABLE", c.request_id);
    }

    let arr = zokor.jarr();
    for p in prefs {
        arr.add(pref_json(p));
    }
    return zokor.no_store(zokor.ok_json(arr.render()));
}

fn put_pref_handler(c: zokor.Ctx[app.App]) -> http.Response {
    let account_id = c.local("account_id");
    let dr: result[UpdatePrefDto, http.Response] = zokor.dto(c);
    guard let body = dr else let bad = err_of(dr) {
        return bad;
    }

    let in_app = true;
    if let ia = body.in_app { in_app = ia; }

    let email = false;
    if let em = body.email { email = em; }

    let r = notif_svc.set_pref(c.state.notifications, account_id, body.kind, in_app, email);
    guard let _ = r else let e = err_of(r) {
        return zokor.respond(c.errors, "UNAVAILABLE", c.request_id);
    }

    return zokor.no_store(zokor.no_content());
}

fn get_unsubscribe_handler(c: zokor.Ctx[app.App]) -> http.Response {
    let token = c.query("token");
    if len(token) == 0 {
        return zokor.respond(c.errors, "BAD_REQUEST", c.request_id);
    }

    let now_s = (time.mono() / 1000000000) as int;
    let r = notif_svc.unsubscribe(c.state.notifications, token, now_s);
    guard let _ = r else let e = err_of(r) {
        if e == "TOKEN_EXPIRED" {
            return zokor.respond(c.errors, "TOKEN_EXPIRED", c.request_id);
        }
        return zokor.respond(c.errors, "INVALID_TOKEN", c.request_id);
    }

    let body = zokor.jobj()
        .set_str("status", "ok")
        .set_str("message", "You have been unsubscribed from this notification email.");
    return zokor.no_store(zokor.ok_json(body.render()));
}

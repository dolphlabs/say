// zokor:public
import "http";
import "json";
import "strings";
import "time";
import "zokor";
import "../domain" as domain;
import "../service" as service;
import "../../platform/app" as app;
import "../../platform/auth" as auth;
import "../../platform/config" as config;

gc struct RawClientOp {
    op: str,
    channels: [str],
    channel: str,
    generation: str
}

pub fn stream_ws_rules() -> zokor.WsRules {
    let rules = zokor.default_ws();
    rules.max_frame_bytes = domain.max_inbound_message_bytes();
    rules.max_message_bytes = domain.max_inbound_message_bytes();
    rules.ping_interval = domain.ping_interval_ns();
    rules.pong_timeout = domain.ping_interval_ns();
    rules.max_queue = domain.max_outbound_queue_messages();
    rules.close_timeout = 5000000000;
    return rules;
}

pub fn mount(r: zokor.Router[app.App]) -> int {
    r.websocket(
        "/v1/stream",
        stream_open,
        zokor.ws_route(stream_ws_rules(), stream_message).on_close(stream_closed)
    );
    return 0;
}

fn is_origin_allowed(s: config.Settings, origin: str) -> bool {
    if len(origin) == 0 {
        return true;
    }
    if strings.contains(origin, "localhost") || strings.contains(origin, "127.0.0.1") {
        return true;
    }
    if len(s.auth.app_url) > 0 && strings.has_prefix(origin, s.auth.app_url) {
        return true;
    }
    if s.profile == "dev" || s.profile == "test" {
        return true;
    }
    return false;
}

fn stream_open(c: zokor.Ctx[app.App]) -> http.Response {
    let origin = c.header("Origin");
    if len(origin) > 0 {
        if !is_origin_allowed(c.state.settings, origin) {
            return zokor.respond(c.errors, "FORBIDDEN", c.request_id);
        }
    }

    let token = c.cookie(auth.cookie_name());
    if len(token) == 0 {
        token = c.query("token");
    }

    let account_id = "";
    let session_id = "";
    if len(token) > 0 {
        let r = app.authenticate(c.state, token);
        guard let found = r else let e = err_of(r) {
            c.state.settings.server.logger.error("stream", "session lookup failed: " + e);
            return zokor.respond(c.errors, "UNAVAILABLE", c.request_id);
        }
        guard let caller = found else {
            return zokor.respond(c.errors, "UNAUTHENTICATED", c.request_id);
        }
        account_id = caller.account_id;
        session_id = caller.session_hash;
    }

    c.set_local("account_id", account_id);
    c.set_local("session_id", session_id);

    let sock = c.socket();
    let q = service.register_connection(c.state.stream, sock.id, account_id, session_id);
    spawn run_connection_writer(c.state, sock, q);

    return c.accept_ws();
}

fn run_connection_writer(a: app.App, s: zokor.Socket, q: service.BoundedQueue) -> int {
    while true {
        let got = chan_recv(q.notify);
        guard let _n = got else {
            return 0;
        }

        while true {
            let item_opt = service.poll(q);
            guard let item = item_opt else {
                break;
            }

            if item.is_control && item.msg_type == "session.revoked" {
                s.close(domain.close_code_session_revoked(), "session revoked");
                return 0;
            }

            if !s.send_text(item.text) {
                return 0;
            }
        }

        let now_ms = (time.mono() / 1000000) as int;
        if service.check_slow_consumer(q, now_ms) {
            s.close(domain.close_code_slow_consumer(), "slow consumer");
            return 0;
        }
    }
    return 0;
}

fn stream_message(a: app.App, s: zokor.Socket, m: zokor.Message) {
    if m.kind == zokor.Incoming.Binary {
        s.close(domain.close_code_unsupported(), "binary data unsupported");
        return;
    }

    if len(m.text) > domain.max_inbound_message_bytes() {
        s.close(domain.close_code_policy_violation(), "message too large");
        return;
    }

    let decoded: result[RawClientOp, str] = json.decode(m.text);
    guard let req = decoded else {
        let err_resp = domain.make_error_message("invalid_message", "malformed JSON");
        s.send_text(err_resp);
        return;
    }

    let now_ms = (time.mono() / 1000000) as int;

    if req.op == "ping" {
        let pong = domain.make_control_message("pong", "");
        s.send_text(pong);
        return;
    }

    if req.op == "subscribe" {
        let res = service.subscribe(a.stream, s.id, req.channels, now_ms);
        if let accepted = res {
            let detail = "{\"channels\":" + domain.format_string_array(accepted) + "}";
            s.send_text(domain.make_control_message("subscribed", detail));
        } else let e = err_of(res) {
            if e == "RATE_LIMITED" {
                s.send_text(domain.make_error_message("rate_limited", "too many subscribe operations"));
            } else if e == "CHANNEL_LIMIT_EXCEEDED" {
                s.send_text(domain.make_error_message("channel_limit_exceeded", "channel limit exceeded"));
            } else {
                s.send_text(domain.make_error_message("subscription_failed", e));
            }
        }
        return;
    }

    if req.op == "unsubscribe" {
        let removed = service.unsubscribe(a.stream, s.id, req.channels, now_ms);
        let detail = "{\"channels\":" + domain.format_string_array(removed) + "}";
        s.send_text(domain.make_control_message("unsubscribed", detail));
        return;
    }

    if req.op == "resync" {
        let ok_res = service.resync(a.stream, s.id, req.channel, req.generation, now_ms);
        if !ok_res {
            s.send_text(domain.make_error_message("resync_failed", "channel not eligible for resync"));
        }
        return;
    }

    s.send_text(domain.make_error_message("invalid_operation", "unknown operation: " + req.op));
}

fn stream_closed(a: app.App, s: zokor.Socket, code: int, reason: str) {
    let now_ms = (time.mono() / 1000000) as int;
    service.unregister_connection(a.stream, s.id, now_ms);
}

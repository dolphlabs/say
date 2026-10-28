import "strings";
import "../domain" as domain;
import "../../platform/config" as config;

fn test_stream_ws_rules() {
    let r = stream_ws_rules();
    assert(r.max_frame_bytes == 16384);
    assert(r.max_message_bytes == 16384);
    assert(r.max_queue == 256);
    assert(r.ping_interval == 20000000000);
    assert(r.pong_timeout == 20000000000);
}

fn test_is_origin_allowed() {
    let cfg = zokor.load_config();
    let s = config.settings_from(cfg);
    s.auth.app_url = "https://say.fun";
    s.profile = "prod";

    assert(is_origin_allowed(s, ""));
    assert(is_origin_allowed(s, "http://localhost:3000"));
    assert(is_origin_allowed(s, "http://127.0.0.1:8080"));
    assert(is_origin_allowed(s, "https://say.fun"));
    assert(!is_origin_allowed(s, "https://evil.com"));

    s.profile = "dev";
    assert(is_origin_allowed(s, "https://evil.com"));
}

import "strings";
import "../domain" as domain;

fn test_stream_ws_rules() {
    let r = stream_ws_rules();
    assert(r.max_frame_bytes == 16384);
    assert(r.max_message_bytes == 16384);
    assert(r.max_queue == 256);
    assert(r.ping_interval == 20000000000);
    assert(r.pong_timeout == 20000000000);
}

fn test_is_origin_allowed() {
    let app_url = "https://say.fun";
    let profile = "prod";

    assert(is_origin_allowed(app_url, profile, ""));
    assert(is_origin_allowed(app_url, profile, "http://localhost:3000"));
    assert(is_origin_allowed(app_url, profile, "http://127.0.0.1:8080"));
    assert(is_origin_allowed(app_url, profile, "https://say.fun"));
    assert(!is_origin_allowed(app_url, profile, "https://evil.com"));

    assert(is_origin_allowed(app_url, "dev", "https://evil.com"));
}

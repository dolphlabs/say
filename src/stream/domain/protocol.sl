import "strings";

pub gc struct ChannelInfo {
    kind: str,
    market_id: str,
    raw: str,
    valid: bool,
    is_private: bool
}

pub gc struct ClientOp {
    op: str,
    channels: [str],
    channel: str,
    generation: str,
    valid: bool,
    error: str
}

pub fn max_channels_per_connection() -> int {
    return 50;
}

pub fn max_subscribe_ops_per_10s() -> int {
    return 20;
}

pub fn max_inbound_message_bytes() -> int {
    return 16384;
}

pub fn max_outbound_queue_messages() -> int {
    return 256;
}

pub fn max_outbound_queue_bytes() -> int {
    return 1048576; // 1 MB
}

pub fn ping_interval_ns() -> int {
    return 20000000000; // 20s
}

pub fn silence_timeout_ns() -> int {
    return 60000000000; // 60s
}

pub fn slow_consumer_timeout_ns() -> int {
    return 10000000000; // 10s
}

pub fn close_code_normal() -> int { return 1000; }
pub fn close_code_going_away() -> int { return 1001; }
pub fn close_code_protocol_error() -> int { return 1002; }
pub fn close_code_unsupported() -> int { return 1003; }
pub fn close_code_policy_violation() -> int { return 1008; }
pub fn close_code_internal_error() -> int { return 1011; }
pub fn close_code_session_revoked() -> int { return 4001; }
pub fn close_code_slow_consumer() -> int { return 4008; }

pub fn parse_channel(name: str) -> ChannelInfo {
    let raw = strings.trim(name);
    if raw == "cards" {

        return ChannelInfo { kind: "cards", market_id: "", raw: raw, valid: true, is_private: false };
    }
    if raw == "season" {
        return ChannelInfo { kind: "season", market_id: "", raw: raw, valid: true, is_private: false };
    }
    if raw == "me" {
        return ChannelInfo { kind: "me", market_id: "", raw: raw, valid: true, is_private: true };
    }
    if strings.has_prefix(raw, "market:") {
        let parts = strings.split(raw, ":");
        if len(parts) == 3 {
            let mid = parts[1];
            let sub = parts[2];
            if len(mid) >= 1 && (sub == "book" || sub == "trades" || sub == "status") {
                return ChannelInfo {
                    kind: "market." + sub,
                    market_id: mid,
                    raw: raw,
                    valid: true,
                    is_private: false
                };
            }
        }
    }
    return ChannelInfo { kind: "unknown", market_id: "", raw: raw, valid: false, is_private: false };
}

pub fn format_uint64_str(v: int) -> str {
    return to_str(v);
}

pub fn make_event_envelope(
    event_id: str,
    channel: str,
    event_type: str,
    book_seq: int,
    from_seq: int,
    owner_epoch: int,
    ts: str,
    payload_json: str
) -> str {
    let out = "{\"event_id\":\"" + event_id + "\",\"channel\":\"" + channel + "\",\"type\":\"" + event_type + "\"";
    if book_seq > 0 {
        out += ",\"book_seq\":\"" + to_str(book_seq) + "\"";
    }
    if from_seq > 0 {
        out += ",\"from_seq\":\"" + to_str(from_seq) + "\"";
    }
    if owner_epoch > 0 {
        out += ",\"owner_epoch\":\"" + to_str(owner_epoch) + "\"";
    }
    if ts != "" {
        out += ",\"ts\":\"" + ts + "\"";
    }
    if payload_json != "" {
        out += ",\"payload\":" + payload_json;
    } else {
        out += ",\"payload\":{}";
    }
    out += "}";
    return out;
}

pub fn make_control_message(msg_type: str, detail_json: str) -> str {
    let out = "{\"type\":\"" + msg_type + "\"";
    if detail_json != "" {
        out += ",\"detail\":" + detail_json;
    }
    out += "}";
    return out;
}

pub fn make_error_message(code: str, message: str) -> str {
    return "{\"type\":\"error\",\"error\":{\"code\":\"" + code + "\",\"message\":\"" + message + "\"}}";
}

pub fn format_string_array(items: [str]) -> str {
    let out = "[";
    let first = true;
    for s in items {
        if !first {
            out += ",";
        }
        out += "\"" + s + "\"";
        first = false;
    }
    out += "]";
    return out;
}

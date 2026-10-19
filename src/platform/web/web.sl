import "http";
import "strings";
import "zokor";

// The UI's envelope: {"error":{"code","message","retry_after"?,"attempts_left"?,
// "signup_token"?,"fields"?}}. Extra values ride in as field errors with
// reserved names and are lifted to the top level here, so every failure
// still goes through a registered code.
pub fn render(v: zokor.ErrorView) -> http.Response {
    let e = zokor.jobj().set_str("code", public_code(v.code)).set_str("message", v.message);
    let fields = zokor.jarr();
    let field_count = 0;
    let retry = "";
    for f in v.fields {
        if f.field == "retry_after" {
            e.set_int("retry_after", to_int(f.reason) ?? 1);
            retry = f.reason;
        } else if f.field == "attempts_left" {
            e.set_int("attempts_left", to_int(f.reason) ?? 0);
        } else if f.field == "signup_token" {
            e.set_str("signup_token", f.reason);
        } else {
            fields.add(zokor.jobj().set_str("field", f.field).set_str("reason", f.reason));
            field_count += 1;
        }
    }
    if field_count > 0 {
        e.set("fields", fields);
    }
    let resp = zokor.no_store(zokor.json_response(v.status, zokor.jobj().set("error", e).render()));
    if len(retry) > 0 {
        return zokor.with_header(resp, "retry-after", retry);
    }
    return resp;
}

// zokor's own codes are lower-case; the UI's are upper-case.
pub fn public_code(code: str) -> str {
    switch code {
        case "unauthorized" { return "UNAUTHENTICATED"; }
        case "rate_limited" { return "RATE_LIMITED"; }
        default { return strings.to_upper(code); }
    }
}

pub fn extra(name: str, value: str) -> zokor.FieldError {
    return zokor.field(name, value);
}

pub fn register_common(r: zokor.Registry) {
    zokor.set_renderer(r, render);
    zokor.register(r, "UNAUTHENTICATED", 401, "Please log in first.");
    zokor.register(r, "RATE_LIMITED", 429, "Too many tries. Wait a moment and try again.");
    zokor.register(r, "UNAVAILABLE", 503, "Something went wrong on our side. Try again.");
    zokor.register(r, "BUSY", 503, "We are busy right now. Try again in a moment.");
    zokor.register(r, "BAD_REQUEST", 400, "That request is not valid.");
}

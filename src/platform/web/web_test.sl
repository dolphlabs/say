import "zokor";

fn test_should_lift_reserved_fields_to_the_top_of_the_envelope() {
    let v = zokor.ErrorView {
        code: "OTP_INVALID", message: "That code is not right.", status: 400, request_id: "", trace_id: "",
        fields: [zokor.field("attempts_left", "3"), zokor.field("code", "is not right")]
    };
    let resp = render(v);
    let j = zokor.resp_json(resp);
    assert(zokor.resp_status(resp) == 400);
    assert(j.path("error.code").str_or("") == "OTP_INVALID");
    assert(j.path("error.attempts_left").int_or(-1) == 3);
    assert(j.path("error.fields").size() == 1);
}

fn test_should_send_retry_after_as_body_and_header() {
    let v = zokor.ErrorView {
        code: "rate_limited", message: "slow down", status: 429, request_id: "", trace_id: "",
        fields: [zokor.field("retry_after", "42")]
    };
    let resp = render(v);
    assert(zokor.resp_json(resp).path("error.code").str_or("") == "RATE_LIMITED");
    assert(zokor.resp_json(resp).path("error.retry_after").int_or(0) == 42);
    assert(zokor.resp_header(resp, "retry-after") == "42");
}

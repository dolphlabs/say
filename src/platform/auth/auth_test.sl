import "strings";
import "zokor";

fn test_should_issue_a_thirty_day_httponly_secure_lax_cookie() {
    let resp = with_session(zokor.no_content(), "tok123");
    guard let r = resp else let e = err_of(resp) { panic(e); }
    let sc = zokor.resp_header(r, "set-cookie");
    for flag in ["say_session=tok123", "HttpOnly", "Secure", "SameSite=Lax", "Path=/", "Max-Age=2592000"] {
        assert(strings.contains(sc, flag), "missing " + flag + " in " + sc);
    }
}

fn test_should_clear_the_session_cookie() {
    let sc = zokor.resp_header(without_session(zokor.no_content()), "set-cookie");
    assert(strings.contains(sc, "say_session=") && strings.contains(sc, "Max-Age=0"), sc);
}

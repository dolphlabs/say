import "strings";
import "zokor";

fn values(pairs: [str]) -> zokor.Config {
    let m: map[str]str = {};
    let i = 0;
    while i + 1 < len(pairs) {
        m[pairs[i]] = pairs[i + 1];
        i = i + 2;
    }
    return zokor.config_from_values(m);
}

fn test_should_read_settings_once_with_spec_defaults() {
    let cfg = values(["PORT", "8080", "OTP_SECRET", "0123456789abcdef0123456789abcdef"]);
    let s = settings_from(cfg);
    assert(s.port == 8080);
    assert(s.timezone == "Africa/Lagos");
    assert(s.email.provider == "console");
    assert(s.auth.redis_timeout_ns == 50000000);
    assert(s.auth.pg_timeout_ns == 2000000000);
    assert(s.auth.google_timeout_ns == 5000000000);
    assert(s.email.timeout_ns == 10000000000);
    assert(len(s.auth.reserved_usernames) > 10);
    let ok_cfg = zokor.check(cfg);
    guard let _ok = ok_cfg else let e = err_of(ok_cfg) { panic(e); }
}

fn test_should_require_a_long_otp_secret() {
    let cfg = values(["PORT", "8080", "OTP_SECRET", "short"]);
    let _s = settings_from(cfg);
    let r = zokor.check(cfg);
    guard let _ok = r else let e = err_of(r) {
        assert(strings.contains(e, "OTP_SECRET"), e);
        return;
    }
    panic("short OTP_SECRET accepted");
}

fn test_should_refuse_the_console_email_provider_outside_dev() {
    let cfg = values(["PORT", "8080", "OTP_SECRET", "0123456789abcdef0123456789abcdef", "EMAIL_PROVIDER", "console"]);
    cfg.profile = "prod";
    let _s = settings_from(cfg);
    let r = zokor.check(cfg);
    guard let _ok = r else let e = err_of(r) {
        assert(strings.contains(e, "EMAIL_PROVIDER"), e);
        return;
    }
    panic("console email accepted in prod");
}

fn test_should_split_and_lowercase_reserved_usernames() {
    let cfg = values(["PORT", "8080", "OTP_SECRET", "0123456789abcdef0123456789abcdef", "RESERVED_USERNAMES", " Say , ADMIN,,x "]);
    let s = settings_from(cfg);
    assert(inspect(s.auth.reserved_usernames) == inspect(["say", "admin", "x"]), inspect(s.auth.reserved_usernames));
}

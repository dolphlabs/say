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
    assert(s.exchange.lease_seconds==10 && s.exchange.heartbeat_ns==2000000000);
    assert(s.exchange.reply_wait_ns==300000000 && s.exchange.max_waiters==1024);
    let ok_cfg = zokor.check(cfg);
    guard let _ok = ok_cfg else let e = err_of(ok_cfg) { panic(e); }
}

fn test_runtime_heartbeat_and_capacity_settings_are_validated_together() {
    let cfg=values(["PORT","8080","OTP_SECRET","0123456789abcdef0123456789abcdef",
        "EXCHANGE_LEASE_SECONDS","3","EXCHANGE_HEARTBEAT","2s","EXCHANGE_MAX_WAITERS","0"]);
    let _settings=settings_from(cfg);
    let checked=zokor.check(cfg);
    if let _valid=checked { panic("unsafe runtime settings accepted"); }
    else let error=err_of(checked) {
        assert(strings.contains(error,"EXCHANGE_HEARTBEAT"));
        assert(strings.contains(error,"EXCHANGE_MAX_WAITERS"));
    }
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

fn test_should_default_to_sendbyte_in_dev_when_a_key_is_set() {
    let cfg = values(["PORT", "8080", "OTP_SECRET", "0123456789abcdef0123456789abcdef", "SEND_BYTE_KEY", "sb-key-12345678"]);
    let s = settings_from(cfg);
    assert(s.email.provider == "sendbyte");
    assert(s.email.sendbyte_api_key == "sb-key-12345678");
}

fn test_should_keep_console_in_the_test_profile_even_with_a_key() {
    let cfg = values(["PORT", "8080", "OTP_SECRET", "0123456789abcdef0123456789abcdef", "SENDBYTE_API_KEY", "sb-key-12345678"]);
    cfg.profile = "test";
    let s = settings_from(cfg);
    assert(s.email.provider == "console");
}

fn test_should_require_a_sendbyte_key_in_prod() {
    let cfg = values(["PORT", "8080", "OTP_SECRET", "0123456789abcdef0123456789abcdef"]);
    cfg.profile = "prod";
    let _s = settings_from(cfg);
    let r = zokor.check(cfg);
    guard let _ok = r else let e = err_of(r) {
        assert(strings.contains(e, "SENDBYTE_API_KEY"), e);
        return;
    }
    panic("prod accepted without a sendbyte key");
}

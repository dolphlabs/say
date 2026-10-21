import "zokor";
import "../config" as config;
import "../email" as email;
import "../../accounts/service" as accounts;

fn settings() -> config.Settings {
    let m: map[str]str = {};
    m["PORT"] = "9000";
    m["OTP_SECRET"] = "app-test-otp-secret-0123456789abcdef";
    m["RESERVED_USERNAMES"] = "say,admin";
    return config.settings_from(zokor.config_from_values(m));
}

fn test_should_carry_settings_into_the_auth_config() {
    let c = auth_config(settings(), "dummy");
    assert(c.session_ttl_seconds == 2592000);
    assert(c.signup_ttl_seconds == 1800);
    assert(c.hold_seconds == 600);
    assert(len(c.otp_secret) >= 32);
    assert(inspect(c.reserved) == inspect(["say", "admin"]));
}

fn test_should_render_verify_and_reset_mail_by_purpose() {
    let mem = email.in_memory();
    let m = mailer_on(mem, "say <verify@say.test>");
    let send = m.send;
    let a = send(m.context, accounts_mail("x@say.test", "verify_email"));
    let b = send(m.context, accounts_mail("y@say.test", "reset_password"));
    guard let _a = a else { panic("verify mail"); }
    guard let _b = b else { panic("reset mail"); }
    let sent = email.sent_messages(mem);
    assert(len(sent) == 2);
    assert(sent[0].subject == "Your say code");
    assert(sent[1].subject == "Reset your say password");
}

fn test_should_make_distinct_v4_uuids() {
    let a = new_uuid();
    let b = new_uuid();
    assert(len(a) == 36 && a != b, a);
}

fn accounts_mail(to: str, purpose: str) -> accounts.Mail {
    return accounts.Mail { to: to, username: "u", purpose: purpose, code: "123456" };
}

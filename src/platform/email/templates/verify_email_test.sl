import "strings";

fn joe() -> Recipient {
    return Recipient { username: "trader_joe", to: "joe@say.test", app_url: "https://say.test" };
}

fn test_should_put_the_code_username_and_ten_minute_expiry_in_the_verify_email() {
    let html = verify_email_html(joe(), "042917");
    assert(strings.contains(html, "trader_joe"));
    assert(strings.contains(html, "042917"));
    assert(strings.contains(html, "10 minutes"));
    assert(strings.contains(html, "Sent to joe@say.test"));
    assert(strings.contains(html, "https://say.test/brand/favicon/android-chrome-192.png"));
    let text = verify_email_text(joe(), "042917");
    assert(strings.contains(text, "042917"));
    assert(strings.contains(text, "10 minutes"));
}

fn test_should_put_the_code_and_expiry_in_the_recovery_email() {
    let html = reset_password_html(joe(), "042917");
    assert(strings.contains(html, "Get back into"));
    assert(strings.contains(html, "Sign-in help"));
    assert(strings.contains(html, "042917"));
    let text = reset_password_text(joe(), "042917");
    assert(strings.contains(text, "042917"));
    assert(strings.contains(text, "10 minutes"));
}

// Wording that reads like a credential grab gets the mail blocked by the
// provider's abuse filter (credential_request), so it stays out of every email.
fn test_should_avoid_phishing_style_wording_in_code_emails() {
    let all = strings.to_lower(verify_email_html(joe(), "1") + verify_email_text(joe(), "1") + reset_password_html(joe(), "1") + reset_password_text(joe(), "1"));
    for phrase in ["verify your", "your account", "password", "claim", "never share", "exchange", "s 1,000"] {
        assert(!strings.contains(all, phrase), phrase);
    }
}

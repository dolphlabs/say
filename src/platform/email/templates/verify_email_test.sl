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

fn notice() -> NoticeEmail {
    return NoticeEmail {
        title: "Market closing soon",
        body: "Will <b>Remo</b> win? closes at 16:00.",
        link_path: "/markets/abc",
        unsubscribe_url: "https://say.test/v1/unsubscribe?token=t.k.1&x=\"y\""
    };
}

fn test_should_escape_market_text_and_link_into_the_notice_email() {
    let html = notice_email_html(joe(), notice());
    assert(strings.contains(html, "Will &lt;b&gt;Remo&lt;/b&gt; win?"), html);
    assert(!strings.contains(html, "<b>Remo"), html);
    assert(strings.contains(html, "href=\"https://say.test/markets/abc\""), html);
    assert(strings.contains(html, "token=t.k.1&amp;x=&quot;y&quot;"), html);
    assert(strings.contains(html, ">Unsubscribe</a>"), html);
    let text = notice_email_text(joe(), notice());
    assert(strings.contains(text, "Open say: https://say.test/markets/abc"), text);
    assert(strings.contains(text, "Unsubscribe: https://say.test/v1/unsubscribe"), text);
}

fn test_should_drop_a_notice_link_that_leaves_say() {
    for path in ["https://evil.test/x", "//evil.test/x", "javascript:alert(1)"] {
        let e = notice();
        let html = notice_email_html(joe(), NoticeEmail { title: e.title, body: e.body, link_path: path, unsubscribe_url: "" });
        assert(!strings.contains(html, "evil.test") && !strings.contains(html, "javascript:"), html);
        assert(!strings.contains(html, "Open say"), html);
        assert(!strings.contains(html, "Unsubscribe"), html);
    }
}

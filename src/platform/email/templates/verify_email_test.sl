import "strings";

fn test_should_put_the_code_username_and_ten_minute_expiry_in_the_verify_email() {
    let html = verify_email_html("trader_joe", "042917");
    assert(strings.contains(html, "trader_joe"));
    assert(strings.contains(html, "042917"));
    assert(strings.contains(html, "10 minutes"));
    let text = verify_email_text("trader_joe", "042917");
    assert(strings.contains(text, "042917"));
    assert(strings.contains(text, "10 minutes"));
}

fn test_should_say_reset_in_the_reset_password_email() {
    let html = reset_password_html("trader_joe", "042917");
    assert(strings.contains(html, "Reset your password"));
    assert(strings.contains(html, "042917"));
    let text = reset_password_text("trader_joe", "042917");
    assert(strings.contains(text, "reset code"));
}

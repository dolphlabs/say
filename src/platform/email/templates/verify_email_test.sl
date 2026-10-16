import "strings";

fn test_verify_email_template_contains_code_and_username() {
    let html = verify_email_html("trader_joe", "A1B2C3D4");
    assert(strings.contains(html, "trader_joe"));
    assert(strings.contains(html, "A1B2C3D4"));
    assert(strings.contains(html, "1 hour"));

    let text = verify_email_text("trader_joe", "A1B2C3D4");
    assert(strings.contains(text, "trader_joe"));
    assert(strings.contains(text, "A1B2C3D4"));
    assert(strings.contains(text, "1 hour"));
}

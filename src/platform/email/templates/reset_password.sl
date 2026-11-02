pub fn reset_password_html(r: Recipient, code: str) -> str {
    return code_email_html(r, CodeEmail {
        title: "Your code to get back into say",
        badge: "Sign-in help",
        lead: "Get back into",
        mark: "say",
        intro: "You asked to get back in. Type this code on the page you just left, then pick new sign-in details.",
        code: code,
        footnote: "Didn't ask for this? Ignore it. Nothing changes without the code."
    });
}

pub fn reset_password_text(r: Recipient, code: str) -> str {
    return "Hi " + r.username + ",\n\n" +
        "You asked to get back in. Type this code on the page you just left, then pick new sign-in details:\n\n" +
        code + "\n\n" +
        "Expires in 10 minutes.\n\n" +
        "Didn't ask for this? Ignore it. Nothing changes without the code.\n\n" +
        "-- the say crew\n" +
        "say is a free prediction game by Dolphlabs. Sedis are play credits with no cash value.";
}

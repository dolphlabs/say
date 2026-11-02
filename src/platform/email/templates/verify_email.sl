pub fn verify_email_html(r: Recipient, code: str) -> str {
    return code_email_html(r, CodeEmail {
        title: "Finish signing up for say",
        badge: "Your code",
        lead: "Here's your",
        mark: "code",
        intro: "Type this into say to finish signing up.",
        code: code,
        footnote: "Didn't sign up for say? Ignore this email and nothing happens."
    });
}

pub fn verify_email_text(r: Recipient, code: str) -> str {
    return "Hi " + r.username + ",\n\n" +
        "Type this into say to finish signing up:\n\n" +
        code + "\n\n" +
        "Expires in 10 minutes.\n\n" +
        "Didn't sign up for say? Ignore this email and nothing happens.\n\n" +
        "-- the say crew\n" +
        "say is a free prediction game by Dolphlabs. Sedis are play credits with no cash value.";
}

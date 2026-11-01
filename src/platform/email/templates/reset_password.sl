pub fn reset_password_html(username: str, code: str) -> str {
    return code_email_html(
        "Your code to get back into say",
        "Get back into say",
        username,
        "You asked to get back into say. Type this code into the page you just left, then choose new sign-in details.",
        code,
        "If you didn't ask for this, ignore this email. Nothing changes without the code."
    );
}

pub fn reset_password_text(username: str, code: str) -> str {
    return "Hi " + username + ",\n\n" +
        "You asked to get back into say. Your code is:\n\n" +
        code + "\n\n" +
        "This code expires in 10 minutes. Type it into the page you just left, then choose new sign-in details.\n\n" +
        "If you didn't ask for this, ignore this email. Nothing changes without the code.\n\n" +
        "-- say, the free prediction game";
}

pub fn verify_email_html(username: str, code: str) -> str {
    return code_email_html(
        "Verify your say account",
        "Verify your email address",
        username,
        "Welcome to Say. Enter this code to verify your email and claim your S 1,000.",
        code,
        "If you did not sign up, you can ignore this email. Never share this code with anyone."
    );
}

pub fn verify_email_text(username: str, code: str) -> str {
    return "Hi " + username + ",\n\n" +
        "Welcome to Say. Your verification code is:\n\n" +
        code + "\n\n" +
        "This code expires in 10 minutes.\n\n" +
        "If you did not request this, please disregard this email.\n\n" +
        "-- Say Exchange";
}

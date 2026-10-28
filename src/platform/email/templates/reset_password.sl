pub fn reset_password_html(username: str, code: str) -> str {
    return code_email_html(
        "Reset your say password",
        "Reset your password",
        username,
        "Enter this code to choose a new password.",
        code,
        "If you did not ask to reset your password, you can ignore this email and your password stays the same. Never share this code with anyone."
    );
}

pub fn reset_password_text(username: str, code: str) -> str {
    return "Hi " + username + ",\n\n" +
        "Your password reset code is:\n\n" +
        code + "\n\n" +
        "This code expires in 10 minutes.\n\n" +
        "If you did not request this, please disregard this email.\n\n" +
        "-- Say Exchange";
}

pub fn verify_email_html(username: str, code: str) -> str {
    return code_email_html(
        "Finish signing up for say",
        "Finish signing up",
        username,
        "Here's the code to finish setting up your say profile. Type it into the sign-up page you just left.",
        code,
        "You're getting this because this address was used to sign up for say. If that wasn't you, ignore this email and nothing will happen."
    );
}

pub fn verify_email_text(username: str, code: str) -> str {
    return "Hi " + username + ",\n\n" +
        "Here's the code to finish setting up your say profile:\n\n" +
        code + "\n\n" +
        "This code expires in 10 minutes. Type it into the sign-up page you just left.\n\n" +
        "You're getting this because this address was used to sign up for say. If that wasn't you, ignore this email and nothing will happen.\n\n" +
        "-- say, the free prediction game";
}

pub fn reset_password_html(username: str, code: str) -> str {
    return "<!DOCTYPE html>" +
        "<html lang=\"en\">" +
        "<head>" +
        "<meta charset=\"UTF-8\">" +
        "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">" +
        "<title>Reset your say password</title>" +
        "</head>" +
        "<body style=\"margin: 0; padding: 0; background-color: #09090b; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; color: #f4f4f5;\">" +
        "<table role=\"presentation\" width=\"100%\" cellspacing=\"0\" cellpadding=\"0\" border=\"0\" style=\"background-color: #09090b; padding: 40px 20px;\">" +
        "<tr><td align=\"center\">" +
        "<table role=\"presentation\" width=\"100%\" max-width=\"540\" cellspacing=\"0\" cellpadding=\"0\" border=\"0\" style=\"max-width: 540px; background-color: #18181b; border: 1px solid #27272a; border-radius: 12px; overflow: hidden;\">" +
        "<tr><td style=\"padding: 32px 32px 24px 32px; border-bottom: 1px solid #27272a; text-align: left;\">" +
        "<div style=\"font-size: 20px; font-weight: 800; letter-spacing: 2px; color: #10b981;\">SAY <span style=\"color: #a1a1aa; font-weight: 400; font-size: 14px;\">EXCHANGE</span></div>" +
        "</td></tr>" +
        "<tr><td style=\"padding: 32px;\">" +
        "<h1 style=\"margin: 0 0 16px 0; font-size: 22px; font-weight: 700; color: #ffffff;\">Reset your password</h1>" +
        "<p style=\"margin: 0 0 24px 0; font-size: 15px; line-height: 24px; color: #a1a1aa;\">Hi <strong style=\"color: #f4f4f5;\">" + username + "</strong>,</p>" +
        "<p style=\"margin: 0 0 24px 0; font-size: 15px; line-height: 24px; color: #a1a1aa;\">Welcome to Say. Use the 6-digit code below to choose a new password:</p>" +
        "<div style=\"margin: 28px 0; text-align: center;\">" +
        "<div style=\"display: inline-block; background-color: #09090b; border: 1px solid #10b981; border-radius: 8px; padding: 16px 28px; font-family: 'SF Mono', Menlo, Consolas, Monaco, monospace; font-size: 32px; font-weight: 800; letter-spacing: 6px; color: #10b981;\">" +
        code +
        "</div>" +
        "</div>" +
        "<p style=\"margin: 0 0 16px 0; font-size: 13px; line-height: 20px; color: #71717a;\">⏳ This code expires in <strong style=\"color: #a1a1aa;\">10 minutes</strong>.</p>" +
        "<p style=\"margin: 0; font-size: 13px; line-height: 20px; color: #71717a;\">If you did not ask to reset your password, ignore this email; your password stays the same. Never share this code with anyone.</p>" +
        "</td></tr>" +
        "<tr><td style=\"padding: 24px 32px; background-color: #09090b; border-top: 1px solid #27272a; text-align: center;\">" +
        "<p style=\"margin: 0; font-size: 12px; color: #52525b;\">&copy; Say Exchange. Virtual prediction market kernel.</p>" +
        "</td></tr>" +
        "</table>" +
        "</td></tr>" +
        "</table>" +
        "</body>" +
        "</html>";
}

pub fn reset_password_text(username: str, code: str) -> str {
    return "Hi " + username + ",\n\n" +
        "Your password reset code is:\n\n" +
        code + "\n\n" +
        "This code expires in 10 minutes.\n\n" +
        "If you did not request this, please disregard this email.\n\n" +
        "-- Say Exchange";
}

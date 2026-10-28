fn code_email_html(title: str, heading: str, username: str, intro: str, code: str, footnote: str) -> str {
    return "<!DOCTYPE html>" +
        "<html lang=\"en\">" +
        "<head>" +
        "<meta charset=\"UTF-8\">" +
        "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">" +
        "<meta name=\"color-scheme\" content=\"light\">" +
        "<title>" + title + "</title>" +
        "</head>" +
        "<body style=\"margin: 0; padding: 0; background-color: #ffffff; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; color: #18181b;\">" +
        "<table role=\"presentation\" width=\"100%\" cellspacing=\"0\" cellpadding=\"0\" border=\"0\" style=\"background-color: #ffffff;\">" +
        "<tr><td align=\"center\" style=\"padding: 48px 24px;\">" +
        "<table role=\"presentation\" width=\"100%\" cellspacing=\"0\" cellpadding=\"0\" border=\"0\" style=\"max-width: 480px;\">" +
        "<tr><td style=\"padding-bottom: 32px; font-size: 18px; font-weight: 700; letter-spacing: -0.2px; color: #18181b;\">say</td></tr>" +
        "<tr><td style=\"padding-bottom: 16px; font-size: 22px; line-height: 28px; font-weight: 600; color: #18181b;\">" + heading + "</td></tr>" +
        "<tr><td style=\"padding-bottom: 24px; font-size: 16px; line-height: 24px; color: #3f3f46;\">Hi " + username + ",<br><br>" + intro + "</td></tr>" +
        "<tr><td style=\"padding-bottom: 24px;\">" +
        "<div style=\"background-color: #f4f4f5; border-radius: 8px; padding: 20px; text-align: center; font-family: 'SF Mono', Menlo, Consolas, monospace; font-size: 32px; font-weight: 600; letter-spacing: 8px; color: #18181b;\">" + code + "</div>" +
        "</td></tr>" +
        "<tr><td style=\"padding-bottom: 32px; font-size: 14px; line-height: 22px; color: #52525b;\">This code expires in 10 minutes. " + footnote + "</td></tr>" +
        "<tr><td style=\"border-top: 1px solid #e4e4e7; padding-top: 16px; font-size: 12px; line-height: 18px; color: #a1a1aa;\">Say Exchange</td></tr>" +
        "</table>" +
        "</td></tr>" +
        "</table>" +
        "</body>" +
        "</html>";
}

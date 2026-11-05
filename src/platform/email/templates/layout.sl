import "builder";
import "strings";

pub struct Recipient {
    username: str,
    to: str,
    app_url: str
}

pub struct CodeEmail {
    title: str,
    badge: str,
    lead: str,
    mark: str,
    intro: str,
    code: str,
    footnote: str
}

fn font() -> str {
    return "'Instrument Sans', -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif";
}

fn display_font() -> str {
    return "'Bricolage Grotesque', " + font();
}

// Text that reaches an email from anywhere but this file (market questions,
// usernames, links) is escaped before it is placed in HTML.
pub fn escape_html(s: str) -> str {
    let out = builder.new_bytes();
    for b in to_bytes(s) {
        if b == 38 { out.write_str("&amp;"); }
        else if b == 60 { out.write_str("&lt;"); }
        else if b == 62 { out.write_str("&gt;"); }
        else if b == 34 { out.write_str("&quot;"); }
        else if b == 39 { out.write_str("&#39;"); }
        else { out.write_byte(b); }
    }
    let done = out.finish();
    return strings.from_bytes(done, 0, len(done));
}

fn frame(r: Recipient, title: str, rows: str, extra_links: str) -> str {
    let display = display_font();
    return "<!DOCTYPE html>" +
        "<html lang=\"en\">" +
        "<head>" +
        "<meta charset=\"UTF-8\">" +
        "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">" +
        "<meta name=\"color-scheme\" content=\"light\">" +
        "<title>" + title + "</title>" +
        "</head>" +
        "<body style=\"margin: 0; padding: 0; background-color: #ffffff; font-family: " + font() + "; color: #15171d;\">" +
        "<table role=\"presentation\" width=\"100%\" cellspacing=\"0\" cellpadding=\"0\" border=\"0\" style=\"background-color: #ffffff;\">" +
        "<tr><td align=\"center\" style=\"padding: 56px 24px 64px;\">" +
        "<table role=\"presentation\" width=\"100%\" cellspacing=\"0\" cellpadding=\"0\" border=\"0\" style=\"max-width: 520px;\">" +
        "<tr><td style=\"padding-bottom: 28px;\">" +
        "<a href=\"" + r.app_url + "\" style=\"text-decoration: none; color: #15171d;\">" +
        "<img src=\"" + r.app_url + "/brand/favicon/android-chrome-192.png\" width=\"40\" height=\"40\" alt=\"\" style=\"display: inline-block; vertical-align: middle; border: 0;\">" +
        "<span style=\"display: inline-block; vertical-align: middle; padding-left: 10px; font-family: " + display + "; font-size: 26px; font-weight: 800; letter-spacing: -1px;\">say</span>" +
        "</a></td></tr>" +
        rows +
        "<tr><td style=\"padding-bottom: 10px; font-family: " + display + "; font-size: 16px; font-weight: 800; color: #15171d;\">— the say crew</td></tr>" +
        "<tr><td style=\"padding-bottom: 10px; font-size: 12px; line-height: 18px; color: #7c808b;\">say is a free prediction game by Dolphlabs. Sedis are play credits with no cash value.</td></tr>" +
        "<tr><td style=\"font-size: 12px; line-height: 18px; color: #7c808b;\">" +
        "<a href=\"" + r.app_url + "/how-it-works\" style=\"color: #5b5f6b; text-decoration: underline;\">Help</a> · " +
        "<a href=\"" + r.app_url + "/settings\" style=\"color: #5b5f6b; text-decoration: underline;\">Email settings</a> · " +
        extra_links +
        "Sent to " + r.to +
        "</td></tr>" +
        "</table>" +
        "</td></tr>" +
        "</table>" +
        "</body>" +
        "</html>";
}

fn badge_row(badge: str) -> str {
    return "<tr><td style=\"padding-bottom: 12px;\">" +
        "<span style=\"display: inline-block; background-color: #f1f8dc; border-radius: 999px; padding: 5px 10px; font-size: 12px; font-weight: 700; letter-spacing: 0.6px; text-transform: uppercase; color: #3d4a12;\">" + badge + "</span>" +
        "</td></tr>";
}

fn code_email_html(r: Recipient, e: CodeEmail) -> str {
    let display = display_font();
    let rows = badge_row(e.badge) +
        "<tr><td style=\"padding-bottom: 24px; font-family: " + display + "; font-size: 38px; line-height: 46px; font-weight: 800; letter-spacing: -1.4px; color: #15171d;\">" +
        e.lead + " <span style=\"background-color: #d4f25c; border-radius: 8px; padding: 0 8px;\">" + e.mark + "</span>." +
        "</td></tr>" +
        "<tr><td style=\"padding-bottom: 28px; font-size: 17px; line-height: 27px; color: #2a2d36;\">Hi " + r.username + ",<br><br>" + e.intro + "</td></tr>" +
        "<tr><td>" +
        "<div style=\"background-color: #d4f25c; border-radius: 22px; padding: 26px 20px 22px; text-align: center;\">" +
        "<div style=\"font-family: " + display + "; font-size: 44px; line-height: 50px; font-weight: 800; letter-spacing: 10px; color: #0d0e12;\">" + e.code + "</div>" +
        "<div style=\"padding-top: 8px; font-size: 13px; font-weight: 600; color: #2f3a0c;\">Expires in 10 minutes</div>" +
        "</div>" +
        "<div style=\"margin-left: 46px; width: 0; height: 0; border-top: 20px solid #d4f25c; border-right: 26px solid transparent;\"></div>" +
        "</td></tr>" +
        "<tr><td style=\"padding: 28px 0 48px; font-size: 15px; line-height: 23px; color: #5b5f6b;\">" + e.footnote + "</td></tr>";
    return frame(r, e.title, rows, "");
}

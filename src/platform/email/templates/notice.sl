import "strings";

pub struct NoticeEmail {
    title: str,
    body: str,
    link_path: str,
    unsubscribe_url: str
}

// Only paths inside say become buttons, so a notice can never point a player
// at another site.
fn notice_link(r: Recipient, path: str) -> str {
    if strings.has_prefix(path, "/") && !strings.has_prefix(path, "//") {
        return r.app_url + path;
    }
    return "";
}

pub fn notice_email_html(r: Recipient, e: NoticeEmail) -> str {
    let display = display_font();
    let title = escape_html(e.title);
    let href = notice_link(r, e.link_path);
    let rows = badge_row("Heads up") +
        "<tr><td style=\"padding-bottom: 24px; font-family: " + display + "; font-size: 34px; line-height: 42px; font-weight: 800; letter-spacing: -1.2px; color: #15171d;\">" +
        title + "</td></tr>" +
        "<tr><td style=\"padding-bottom: 28px; font-size: 17px; line-height: 27px; color: #2a2d36;\">Hi " + escape_html(r.username) + ",<br><br>" +
        escape_html(e.body) + "</td></tr>";
    if len(href) > 0 {
        rows = rows + "<tr><td style=\"padding-bottom: 48px;\">" +
            "<a href=\"" + escape_html(href) + "\" style=\"display: inline-block; background-color: #d4f25c; border-radius: 999px; padding: 14px 24px; font-family: " + display + "; font-size: 16px; font-weight: 800; color: #0d0e12; text-decoration: none;\">Open say</a>" +
            "</td></tr>";
    }
    let unsubscribe = "";
    if len(e.unsubscribe_url) > 0 {
        unsubscribe = "<a href=\"" + escape_html(e.unsubscribe_url) + "\" style=\"color: #5b5f6b; text-decoration: underline;\">Unsubscribe</a> · ";
    }
    return frame(Recipient { username: r.username, to: escape_html(r.to), app_url: r.app_url }, title, rows, unsubscribe);
}

pub fn notice_email_text(r: Recipient, e: NoticeEmail) -> str {
    let out = "Hi " + r.username + ",\n\n" + e.body + "\n\n";
    let href = notice_link(r, e.link_path);
    if len(href) > 0 {
        out = out + "Open say: " + href + "\n\n";
    }
    out = out + "-- the say crew\n" +
        "say is a free prediction game by Dolphlabs. Sedis are play credits with no cash value.";
    if len(e.unsubscribe_url) > 0 {
        out = out + "\nUnsubscribe: " + e.unsubscribe_url;
    }
    return out;
}

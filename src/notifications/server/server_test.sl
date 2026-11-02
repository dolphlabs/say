import "strings";
import "zokor";
import "../domain" as domain;

fn test_item_json_rendering() {
    let item = domain.NotificationItem {
        id: "notif-1",
        kind: "order_filled",
        dedupe_key: "order_filled:ord-1",
        title: "Order filled",
        body: "6 Enyimba Yes @ S 54.",
        link_url: "/portfolio",
        data: "{}",
        created_at: "2026-10-28T12:00:00Z",
        updated_at: "2026-10-28T12:00:00Z",
        unread: true
    };
    let json_obj = item_json(item);
    let s = json_obj.render();
    assert(strings.contains(s, "Order filled"));
    assert(strings.contains(s, "notif-1"));
}

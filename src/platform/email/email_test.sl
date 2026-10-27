import "strings";
import "time";
fn test_memory_email_sender_records_sent_messages() {
    let svc = in_memory();
    let msg = EmailMessage {
        from: "Say <verify@say.exchange>",
        to: ["trader@say.exchange"],
        subject: "Verify your email",
        html: "<p>code: 12345678</p>",
        text: "code: 12345678",
        tags: ["test"]
    };
    let r = send(svc, msg);
    guard let _ok = r else { panic("send failed"); }

    guard let mem = svc.memory else { panic("memory sender missing"); }
    assert(len(mem.sent) == 1);
    assert(mem.sent[0].subject == "Verify your email");
}

fn test_should_time_out_a_send_to_an_unreachable_provider() {
    let e = on_sendbyte("key-12345678", "http://10.255.255.1/v1/emails", 200000000);
    let t0 = time.mono();
    let r = send(e, EmailMessage { from: "a@say.test", to: ["b@say.test"], subject: "s", html: "", text: "", tags: [] });
    let took_ms = ((time.mono() - t0) as int) / 1000000;
    guard let _ok = r else let msg = err_of(r) {
        assert(took_ms < 2000, "took " + to_str(took_ms) + " ms");
        assert(strings.contains(msg, "timeout") || strings.contains(msg, "timed out"), msg);
        return;
    }
    panic("sent to an unreachable provider");
}

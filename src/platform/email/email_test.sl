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

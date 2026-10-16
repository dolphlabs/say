import "builder";
import "httpc";
import "strings";
import "time";
import "zokor";

pub gc struct EmailMessage {
    from: str,
    to: [str],
    subject: str,
    html: str,
    text: str,
    tags: [str]
}

pub gc struct MemorySender {
    lock: mutex,
    sent: [EmailMessage]
}

pub gc struct SendByteSender {
    api_key: str
}

pub gc struct Email {
    sendbyte: opt[SendByteSender],
    memory: opt[MemorySender]
}

pub fn in_memory() -> Email {
    let list: [EmailMessage] = [];
    let none_sb: opt[SendByteSender] = none;
    return Email {
        sendbyte: none_sb,
        memory: some(MemorySender { lock: make_mutex(), sent: list })
    };
}

pub fn on_sendbyte(api_key: str) -> Email {
    let none_mem: opt[MemorySender] = none;
    return Email {
        sendbyte: some(SendByteSender { api_key: api_key }),
        memory: none_mem
    };
}

pub fn send(e: Email, msg: EmailMessage) -> result[bool, str] {
    if let sb = e.sendbyte {
        return sendbyte_send(sb, msg);
    }
    if let m = e.memory {
        return memory_send(m, msg);
    }
    return err("no email sender configured");
}

pub fn sent_messages(e: Email) -> [EmailMessage] {
    let out: [EmailMessage] = [];
    if let m = e.memory {
        mutex_lock(m.lock);
        for msg in m.sent {
            push(out, msg);
        }
        mutex_unlock(m.lock);
    }
    return out;
}

fn memory_send(m: MemorySender, msg: EmailMessage) -> result[bool, str] {
    mutex_lock(m.lock);
    push(m.sent, msg);
    mutex_unlock(m.lock);
    return ok(true);
}

fn sendbyte_send(s: SendByteSender, msg: EmailMessage) -> result[bool, str] {
    if s.api_key == "" {
        println("[SendByte Dev] No API key configured. Email to " + strings.join(msg.to, ", ") + " with subject: " + msg.subject);
        return ok(true);
    }

    let to_arr = zokor.jarr();
    for recipient in msg.to {
        to_arr.add_str(recipient);
    }
    let tags_arr = zokor.jarr();
    for tag in msg.tags {
        tags_arr.add_str(tag);
    }
    let payload = zokor.jobj()
        .set_str("from", msg.from)
        .set("to", to_arr)
        .set_str("subject", msg.subject)
        .set_str("html", msg.html)
        .set_str("text", msg.text)
        .set("tags", tags_arr)
        .render();

    let client = httpc.new_client();
    let req = httpc.new_request("POST", "https://api.sendbyte.africa/v1/emails");
    req.headers["Authorization"] = "Bearer " + s.api_key;
    req.headers["Content-Type"] = "application/json";
    req.body = builder.new_bytes().write_str(payload).finish();

    let deadline = until_of(time.mono() + 10000000000); // 10 seconds
    let r = httpc.client_send(client, req, deadline);
    guard let resp = r else let err_str = err_of(r) {
        return err("SendByte request failed: " + err_str);
    }
    if resp.status < 200 || resp.status >= 300 {
        let body_str = strings.from_bytes(resp.body, 0, len(resp.body));
        let code_str = builder.new_str().write_int(resp.status).finish();
        return err("SendByte returned status " + code_str + ": " + body_str);
    }
    return ok(true);
}

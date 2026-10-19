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
    api_key: str,
    url: str,
    timeout_ns: int,
    client: httpc.Client
}

// Exactly one of these is set. `console` prints the message, code included,
// and settings refuse it outside the dev and test profiles.
pub gc struct Email {
    sendbyte: opt[SendByteSender],
    memory: opt[MemorySender],
    console: bool
}

pub fn in_memory() -> Email {
    let list: [EmailMessage] = [];
    let none_sb: opt[SendByteSender] = none;
    return Email { sendbyte: none_sb, memory: some(MemorySender { lock: make_mutex(), sent: list }), console: false };
}

pub fn on_console() -> Email {
    let none_sb: opt[SendByteSender] = none;
    let none_mem: opt[MemorySender] = none;
    return Email { sendbyte: none_sb, memory: none_mem, console: true };
}

pub fn on_sendbyte(api_key: str, url: str, timeout_ns: int) -> Email {
    let none_mem: opt[MemorySender] = none;
    return Email {
        sendbyte: some(SendByteSender { api_key: api_key, url: url, timeout_ns: timeout_ns, client: httpc.new_client() }),
        memory: none_mem,
        console: false
    };
}

pub fn send(e: Email, msg: EmailMessage) -> result[bool, str] {
    if let sb = e.sendbyte {
        return sendbyte_within(sb, msg);
    }
    if let m = e.memory {
        return memory_send(m, msg);
    }
    if e.console {
        println("[email:dev] to " + strings.join(msg.to, ", ") + " | " + msg.subject + "\n" + msg.text);
        return ok(true);
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

gc struct SendCall {
    s: SendByteSender,
    msg: EmailMessage,
    out: chan[result[bool, str]]
}

fn run_send(x: SendCall) {
    let r = sendbyte_send(x.s, x.msg);
    select {
        case chan_send(x.out, r) {}
        default {}
    }
}

fn send_timer(out: chan[result[bool, str]], ns: int) {
    time.sleep(ns);
    select {
        case chan_send(out, err("sendbyte timed out")) {}
        default {}
    }
}

// httpc does not bound the connect itself, so the send races a timer: the
// outbox gets its answer by the deadline and retries later either way.
fn sendbyte_within(s: SendByteSender, msg: EmailMessage) -> result[bool, str] {
    let out: chan[result[bool, str]] = make_chan(2);
    spawn run_send(SendCall { s: s, msg: msg, out: out });
    spawn send_timer(out, s.timeout_ns);
    let got = chan_recv(out);
    guard let r = got else {
        return err("sendbyte gave no answer");
    }
    return r;
}

fn sendbyte_send(s: SendByteSender, msg: EmailMessage) -> result[bool, str] {
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
    let req = httpc.new_request("POST", s.url);
    req.headers["Authorization"] = "Bearer " + s.api_key;
    req.headers["Content-Type"] = "application/json";
    req.body = builder.new_bytes().write_str(payload).finish();
    req.max_redirects = 0;
    let r = s.client.send(req, until_of(time.mono() + s.timeout_ns));
    guard let resp = r else let e = err_of(r) {
        return err("sendbyte request failed: " + e);
    }
    if resp.status < 200 || resp.status >= 300 {
        return err("sendbyte returned status " + to_str(resp.status));
    }
    return ok(true);
}

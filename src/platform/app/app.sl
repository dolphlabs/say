import "crypto";
import "encoding";
import "strings";
import "zokor";
import "../config" as config;
import "../db" as db;
import "../cache" as cache;
import "../email" as email;
import "../../accounts/service" as accounts;
import "../../accounts/store" as accounts_store;

import "../email/templates" as email_templates;

fn new_uuid() -> str {
    let rb = crypto.rand(16);
    guard let b = rb else {
        return "00000000-0000-0000-0000-000000000000";
    }
    let h = encoding.hex_encode(b);
    return strings.slice(h, 0, 8) + "-" + strings.slice(h, 8, 12) + "-4" + strings.slice(h, 13, 16) + "-a" + strings.slice(h, 17, 20) + "-" + strings.slice(h, 20, 32);
}

pub gc struct App {
    accounts: accounts.Accounts[accounts_store.Store],
    settings: config.Settings,
    db: opt[db.Db],
    cache: opt[cache.Cache],
    email: email.Email
}

pub fn build(s: config.Settings, d: db.Db, c: cache.Cache) -> result[App, str] {
    let some_db: opt[db.Db] = some(d);
    let some_cache: opt[cache.Cache] = some(c);
    let em = email.on_sendbyte(s.sendbyte_api_key);
    return ok(App {
        accounts: accounts.new_accounts(accounts_store.on_postgres(d.pool), new_uuid),
        settings: s,
        db: some_db,
        cache: some_cache,
        email: em
    });
}

pub fn for_tests(s: config.Settings) -> App {
    let none_db: opt[db.Db] = none;
    let mem_cache = cache.in_memory();
    let mem_email = email.in_memory();
    return App {
        accounts: accounts.new_accounts(accounts_store.in_memory(), new_uuid),
        settings: s,
        db: none_db,
        cache: some(mem_cache),
        email: mem_email
    };
}

pub fn save_verification_code(a: App, code: str, email_addr: str, seconds: int) -> result[bool, str] {
    guard let c = a.cache else {
        return err("no cache configured");
    }
    let key = "auth:verify:" + code;
    return cache.set_ex(c, key, seconds, email_addr);
}

pub fn get_verification_code(a: App, code: str) -> result[opt[str], str] {
    guard let c = a.cache else {
        return err("no cache configured");
    }
    let key = "auth:verify:" + code;
    return cache.get(c, key);
}

pub fn delete_verification_code(a: App, code: str) -> result[bool, str] {
    guard let c = a.cache else {
        return err("no cache configured");
    }
    let key = "auth:verify:" + code;
    return cache.delete_key(c, key);
}

gc struct SendEmailJob {
    svc: email.Email,
    from_addr: str,
    to_addr: str,
    username: str,
    code: str
}

fn async_send_verification(job: SendEmailJob) {
    let html = email_templates.verify_email_html(job.username, job.code);
    let text = email_templates.verify_email_text(job.username, job.code);
    let empty_tags: [str] = [];
    let msg = email.EmailMessage {
        from: job.from_addr,
        to: [job.to_addr],
        subject: "Verify your Say Exchange account",
        html: html,
        text: text,
        tags: empty_tags
    };
    let _r = email.send(job.svc, msg);
}

pub fn send_verification_email(a: App, to_addr: str, username: str, code: str) {
    let job = SendEmailJob {
        svc: a.email,
        from_addr: a.settings.email_from,
        to_addr: to_addr,
        username: username,
        code: code
    };
    spawn async_send_verification(job);
}

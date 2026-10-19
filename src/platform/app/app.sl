import "crypto";
import "encoding";
import "strings";
import "timez";
import "zokor";
import "../config" as config;
import "../db" as db;
import "../cache" as cache;
import "../email" as email;
import "../email/templates" as templates;
import "../../accounts/service" as accounts;
import "../../accounts/store" as accounts_store;
import "../../ledger/service" as ledger;
import "../../ledger/store" as ledger_store;

pub gc struct Postman {
    email: email.Email,
    from: str
}

pub gc struct App {
    accounts: accounts.Auth[accounts_store.Store],
    ledger: ledger.Ledger[ledger_store.Postgres],
    mailer: accounts.Mailer[Postman],
    settings: config.Settings,
    db: opt[db.Db],
    cache: opt[cache.Cache]
}

// A failed CSPRNG must fail the request, never hand out a guessable id.
fn new_uuid() -> str {
    let rb = crypto.rand(16);
    guard let b = rb else let e = err_of(rb) {
        panic("crypto.rand failed: " + e);
    }
    let h = encoding.hex_encode(b);
    return strings.slice(h, 0, 8) + "-" + strings.slice(h, 8, 12) + "-4" + strings.slice(h, 13, 16) +
           "-a" + strings.slice(h, 17, 20) + "-" + strings.slice(h, 20, 32);
}

fn send_mail(p: Postman, m: accounts.Mail) -> result[bool, str] {
    let subject = "Your say code";
    let html = templates.verify_email_html(m.username, m.code);
    let text = templates.verify_email_text(m.username, m.code);
    if m.purpose == "reset_password" {
        subject = "Reset your say password";
        html = templates.reset_password_html(m.username, m.code);
        text = templates.reset_password_text(m.username, m.code);
    }
    return email.send(p.email, email.EmailMessage {
        from: p.from, to: [m.to], subject: subject, html: html, text: text, tags: [m.purpose]
    });
}

pub fn mailer_on(e: email.Email, from: str) -> accounts.Mailer[Postman] {
    return accounts.Mailer[Postman] { context: Postman { email: e, from: from }, send: send_mail };
}

fn email_for(s: config.Settings) -> email.Email {
    if s.email.provider == "console" {
        return email.on_console();
    }
    return email.on_sendbyte(s.email.sendbyte_api_key, s.email.sendbyte_url, s.email.timeout_ns);
}

pub fn auth_config(s: config.Settings, dummy_hash: str) -> accounts.AuthConfig {
    let redirect = s.auth.google_redirect_uri;
    return accounts.AuthConfig {
        otp_secret: to_bytes(s.auth.otp_secret),
        reserved: s.auth.reserved_usernames,
        grant_amount: s.season_grant_amount,
        session_ttl_seconds: 2592000,
        signup_ttl_seconds: 1800,
        hold_seconds: 600,
        pending_seconds: 900,
        oauth_state_seconds: 600,
        google_client_id: s.auth.google_client_id,
        google_redirect_uri: redirect,
        google_auth_url: s.auth.google_auth_url,
        dummy_hash: dummy_hash
    };
}

fn wire(s: config.Settings, d: db.Db, c: cache.Cache, mail: email.Email) -> result[App, str] {
    let pool = d.pool;
    let hr = accounts.argon_hash(new_uuid());
    guard let dummy = hr else let e = err_of(hr) {
        return err("argon2id unavailable: " + e);
    }
    let st = accounts_store.new_store(pool, c.pool,
        accounts_store.GoogleEndpoints {
            client_id: s.auth.google_client_id,
            client_secret: s.auth.google_client_secret,
            token_url: s.auth.google_token_url,
            jwks_url: s.auth.google_jwks_url
        },
        accounts_store.Timeouts { pg_ns: s.auth.pg_timeout_ns, redis_ns: s.auth.redis_timeout_ns, google_ns: s.auth.google_timeout_ns });
    let hasher = accounts.new_hasher(s.auth.hash_workers, s.auth.hash_queue, accounts.argon_hash, accounts.argon_verify);
    return ok(App {
        accounts: accounts.new_auth(accounts_store.auth_store(st), auth_config(s, dummy), hasher, new_uuid),
        ledger: ledger.new_ledger(ledger_store.on_postgres(pool, s.auth.pg_timeout_ns)),
        mailer: mailer_on(mail, s.email.from),
        settings: s,
        db: some(d),
        cache: some(c)
    });
}

pub fn build(s: config.Settings, d: db.Db, c: cache.Cache) -> result[App, str] {
    return wire(s, d, c, email_for(s));
}

// The full stack on the given Postgres and Redis (none: Redis is down),
// with mail captured in memory.
pub fn for_tests(s: config.Settings, d: db.Db, c: cache.Cache, mail: email.Email) -> result[App, str] {
    return wire(s, d, c, mail);
}

pub fn current_season_end(a: App) -> result[opt[timez.Time], str] {
    return ledger.current_season_end(a.ledger);
}

// Who a session token belongs to, in terms platform/auth can carry
// without knowing the accounts feature.
pub gc struct Caller {
    account_id: str,
    session_hash: str
}

pub fn authenticate(a: App, token: str) -> result[opt[Caller], str] {
    let none_caller: opt[Caller] = none;
    let r = accounts.authenticate(a.accounts, token);
    guard let found = r else let f = err_of(r) {
        return err(f.detail);
    }
    guard let s = found else {
        return ok(none_caller);
    }
    return ok(some(Caller { account_id: s.account_id, session_hash: encoding.hex_encode(s.token_hash) }));
}

fn drain_problems(a: App) -> int {
    while true {
        let got = chan_recv(a.accounts.problems);
        guard let p = got else {
            return 0;
        }
        a.settings.server.logger.warn("auth", p);
    }
    return 0;
}

// The background half of auth: the audit writer, outbox drainer, expired
// row sweeper and, when Google is configured, the JWKS refresher.
pub fn start_workers(a: App) {
    spawn drain_problems(a);
    spawn accounts.run_audit_writer(a.accounts);
    spawn accounts.run_outbox_worker(a.accounts, a.mailer, 5000);
    spawn accounts.run_cleanup_worker(a.accounts, 600000);
    if len(a.settings.auth.google_client_id) > 0 {
        spawn accounts.run_jwks_refresher(a.accounts);
    }
}

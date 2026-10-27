import "crypto";
import "encoding";
import "strings";
import "time";
import "timez";
import "zokor";
import "../config" as config;
import "../db" as db;
import "../cache" as cache;
import "../email" as email;
import "../email/templates" as templates;
import "../metrics" as metrics;
import "../../accounts/service" as accounts;
import "../../accounts/store" as accounts_store;
import "../../ledger/service" as ledger;
import "../../ledger/store" as ledger_store;
import "../../markets/service" as markets;
import "../../markets/store" as markets_store;
// zokor:imports

pub gc struct Postman {
    email: email.Email,
    from: str
}

pub gc struct App {
    markets: markets.Markets[markets_store.Store],
    // zokor:fields
    accounts: accounts.Auth[accounts_store.Store],
    ledger: ledger.Ledger[ledger_store.Postgres],
    mailer: accounts.Mailer[Postman],
    settings: config.Settings,
    metrics: metrics.Registry,
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
    let zr = timez.load_zone(s.timezone);
    guard let zone = zr else let e = err_of(zr) {
        return err("time zone: " + e);
    }
    let lcfg = ledger.default_config(s.ledger.season_anchor, zone);
    lcfg.grant_workers = s.ledger.grant_workers;
    lcfg.chunk_size = s.ledger.grant_chunk;
    lcfg.recon_every_ns = s.ledger.recon_every_ns;
    let lst = ledger_store.new_postgres(pool, c.pool, s.auth.pg_timeout_ns, s.auth.redis_timeout_ns);
    let hasher = accounts.new_hasher(s.auth.hash_workers, s.auth.hash_queue, accounts.argon_hash, accounts.argon_verify);
    let clock=timez.system_clock();
    let registry=markets.new_markets(markets_store.on_postgres(d.pool,s.auth.pg_timeout_ns,lst,zone),new_uuid,clock);
    registry.snapshot_every_ns=s.markets.snapshot_every_ns;
    registry.close_poll_ns=s.markets.close_poll_ns;
    registry.close_workers=s.markets.close_workers;
    registry.history_generations=s.markets.history_generations;
    return ok(App {
        markets: registry,
        // zokor:build
        accounts: accounts.new_auth(accounts_store.auth_store(st), auth_config(s, dummy), hasher, new_uuid),
        ledger: ledger.new_ledger(ledger_store.ledger_store(lst), lcfg, clock),
        mailer: mailer_on(mail, s.email.from),
        settings: s,
        metrics: metrics.new_registry(),
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
    // zokor:test_build
    return wire(s, d, c, mail);
}

pub fn current_season_end(a: App) -> result[opt[timez.Time], str] {
    return ledger.current_season_end(a.ledger);
}

pub fn market_roles(a: App, id: str) -> result[[str], str] {
    let r = accounts.roles_of(a.accounts,id);
    guard let roles = r else let f = err_of(r) { return err(f.detail); }
    return ok(roles);
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

pub fn has_role(a: App, account_id: str, role: str) -> result[bool, str] {
    let r = accounts.roles_of(a.accounts, account_id);
    guard let roles = r else let f = err_of(r) {
        return err(f.detail);
    }
    for have in roles {
        if have == role || (role == "admin" && have == "super_admin") {
            return ok(true);
        }
    }
    return ok(false);
}

// The ledger's background reports, into the log and the metrics.
fn drain_ledger_signals(a: App) -> int {
    let log = a.settings.server.logger;
    while true {
        let got = chan_recv(a.ledger.signals);
        guard let sig = got else {
            return 0;
        }
        if sig.level == "metric" {
            if sig.text == "gauge" {
                metrics.set(a.metrics, sig.name, sig.value);
            } else {
                metrics.add(a.metrics, sig.name, sig.value);
            }
        } else if sig.level == "critical" {
            log.error("ledger", "CRITICAL " + sig.name + ": " + sig.text);
            metrics.add(a.metrics, "ledger_critical_total", 1);
        } else if sig.level == "warn" {
            log.warn("ledger", sig.name + ": " + sig.text);
        } else {
            log.log("ledger", sig.text);
        }
    }
    return 0;
}

fn run_outbox_publisher(a: App) -> int {
    guard let d = a.db else {
        return 0;
    }
    guard let c = a.cache else {
        return 0;
    }
    let ticks: chan[int] = make_chan(1);
    spawn ledger_ticker(ticks, 5000);
    while true {
        let r = db.publish_outbox(d, c, 100, a.settings.auth.pg_timeout_ns);
        if let n = r {
            if n > 0 {
                metrics.add(a.metrics, "outbox_published_total", n);
                continue;
            }
        } else let e = err_of(r) {
            a.settings.server.logger.warn("outbox", "publish failed: " + e);
        }
        select {
            case let _t = chan_recv(ticks) {}
            case let _k = chan_recv(a.ledger.kicks) {}
        }
    }
    return 0;
}

fn ledger_ticker(ticks: chan[int], every_ms: int) {
    while true {
        time.sleep(every_ms * 1000000);
        select {
            case chan_send(ticks, 1) {}
            default {}
        }
    }
}

// The ledger's long-lived tasks; each takes its own advisory lock, so
// across instances only one runs each job at a time.
pub fn start_ledger_workers(a: App) {
    spawn drain_ledger_signals(a);
    spawn ledger.run_season_scheduler(a.ledger);
    spawn ledger.run_reconciler(a.ledger);
    spawn ledger.run_aggregator(a.ledger);
    spawn run_outbox_publisher(a);
}

// The background half of auth: the audit writer, outbox drainer, expired
// row sweeper and, when Google is configured, the JWKS refresher.
pub fn start_workers(a: App) {
    start_ledger_workers(a);
    spawn markets.run_snapshots(a.markets);
    spawn markets.run_scheduler(a.markets);
    spawn drain_market_signals(a);
    spawn drain_problems(a);
    spawn accounts.run_audit_writer(a.accounts);
    spawn accounts.run_outbox_worker(a.accounts, a.mailer, 5000);
    spawn accounts.run_cleanup_worker(a.accounts, 600000);
    if len(a.settings.auth.google_client_id) > 0 {
        spawn accounts.run_jwks_refresher(a.accounts);
    }
}

fn drain_market_signals(a: App) -> int {
    while true {
        let got=chan_recv(a.markets.problems);
        guard let message=got else { return 0; }
        a.settings.server.logger.warn("markets",message);
    }
    return 0;
}

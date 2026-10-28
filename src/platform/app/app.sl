import "crypto";
import "encoding";
import "json";
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
import "../../exchange/service" as exchange;
import "../../exchange/store" as exchange_store;
import "../../stream/service" as stream_svc;
import "../../stream/store" as stream_store;
import "../../portfolio/service" as portfolio_svc;
import "../../portfolio/store" as portfolio_store;
import "../../notifications/service" as notifications_svc;
import "../../notifications/store" as notifications_store;
import "../../resolution/service" as resolution_svc;
import "../../resolution/store" as resolution_store;
import "../../treasury/service" as treasury;
import "../../treasury/store" as treasury_store;
// zokor:imports

pub gc struct Postman {
    email: email.Email,
    from: str
}

pub gc struct App {
    markets: markets.Markets[markets_store.Store],
    treasury: treasury.TreasuryService[treasury_store.PostgresTreasuryStore],
    // zokor:fields
    accounts: accounts.Auth[accounts_store.Store],
    ledger: ledger.Ledger[ledger_store.Postgres],
    ownership: exchange.Ownership[exchange_store.Postgres],
    heartbeat_ownership: exchange.Ownership[exchange_store.Postgres],
    command_queue: exchange.Queue[exchange_store.Postgres],
    actor_writer: exchange.ActorWriter[exchange_store.Postgres],
    order_admission: exchange.OrderAdmissionStore[exchange_store.Postgres],
    exchange_reads: exchange.ReadStore[exchange_store.Postgres],
    book_views: exchange.BookViewStore[exchange_store.Postgres],
    recovery_store: exchange.RecoveryStore[exchange_store.Postgres],
    stream: stream_svc.StreamService[stream_store.PostgresRedisStore],
    portfolio: portfolio_svc.PortfolioService[portfolio_store.PostgresPortfolioStore],
    notifications: notifications_svc.NotificationService[notifications_store.PostgresNotificationStore],
    resolution: resolution_svc.ResolutionService[resolution_store.PostgresResolutionStore],
    node_id: str,
    runtime: RuntimeControl,
    runtime_views: map[str]str,
    runtime_views_lock: mutex,
    snapshot_queue: chan[exchange.SnapshotWrite],
    reply_slots: chan[int],
    mailer: accounts.Mailer[Postman],
    settings: config.Settings,
    metrics: metrics.Registry,
    db: opt[db.Db],
    cache: opt[cache.Cache]
}

// A failed CSPRNG must fail the request, never hand out a guessable id.
pub fn new_uuid() -> str {
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
    let runtime_store = exchange_store.new_postgres(pool, s.auth.pg_timeout_ns);
    let reserved=db.reserved_pool(s.database_url,s.exchange.heartbeat_pool_size);
    guard let heartbeat_db=reserved else let e=err_of(reserved) { return err("runtime heartbeat pool: "+e); }
    let heartbeat_store=exchange_store.new_postgres(heartbeat_db.pool,s.auth.pg_timeout_ns);
    let ownership = exchange.new_ownership(exchange_store.ownership_store(runtime_store));
    let heartbeat_ownership = exchange.new_ownership(exchange_store.ownership_store(heartbeat_store));
    let command_queue = exchange.new_queue(exchange_store.command_queue(runtime_store));
    let actor_writer = exchange_store.actor_writer(runtime_store);
    let order_admission = exchange_store.order_admission_store(runtime_store);
    let exchange_reads = exchange_store.read_store(runtime_store);
    let book_views = exchange_store.book_view_store(runtime_store);
    let recovery_store = exchange_store.recovery_store(runtime_store);
    let node_id = new_uuid();
    let node_registered = exchange.register_node(ownership, node_id, "say", s.exchange.lease_seconds);
    guard let _registered = node_registered else let e = err_of(node_registered) {
        return err("runtime node registration failed: " + e);
    }
    let hasher = accounts.new_hasher(s.auth.hash_workers, s.auth.hash_queue, accounts.argon_hash, accounts.argon_verify);
    let clock=timez.system_clock();
    let registry=markets.new_markets(markets_store.on_postgres(d.pool,s.auth.pg_timeout_ns,lst,zone),new_uuid,clock);
    registry.snapshot_every_ns=s.markets.snapshot_every_ns;
    registry.close_poll_ns=s.markets.close_poll_ns;
    registry.close_workers=s.markets.close_workers;
    registry.history_generations=s.markets.history_generations;
    let runtime_views:map[str]str={};
    let runtime_views_lock = make_mutex();
    let opt_redis: opt[redis.Pool] = c.pool;
    let s_store = stream_store.make_stream_store(d.pool, opt_redis, runtime_views, runtime_views_lock);
    let s_service = stream_svc.new_stream_service(s_store);
    let port_store = portfolio_store.make_postgres_portfolio_store(d.pool);
    let port_service = portfolio_svc.new_portfolio_service(port_store);
    let notif_store = notifications_store.make_postgres_notification_store(d.pool);
    let notif_service = notifications_svc.new_notification_service(notif_store, s.auth.otp_secret);
    let res_store = resolution_store.make_postgres_resolution_store(d.pool);
    let res_service = resolution_svc.new_resolution_service(res_store);
    let tr_store = treasury_store.make_postgres_treasury_store(d.pool);
    let tr_service = treasury.new_treasury_service(treasury_store.treasury_store(tr_store));
    let snapshot_queue:chan[exchange.SnapshotWrite]=make_chan(64);
    return ok(App {
        markets: registry,
        treasury: tr_service,
        // zokor:build
        accounts: accounts.new_auth(accounts_store.auth_store(st), auth_config(s, dummy), hasher, new_uuid),
        ledger: ledger.new_ledger(ledger_store.ledger_store(lst), lcfg, clock),
        ownership: ownership,
        heartbeat_ownership: heartbeat_ownership,
        command_queue: command_queue,
        actor_writer: actor_writer,
        order_admission: order_admission,
        exchange_reads: exchange_reads,
        book_views: book_views,
        recovery_store: recovery_store,
        stream: s_service,
        portfolio: port_service,
        notifications: notif_service,
        resolution: res_service,
        node_id: node_id,
        runtime: new_runtime_control(),
        runtime_views: runtime_views,
        runtime_views_lock: runtime_views_lock,
        snapshot_queue: snapshot_queue,
        reply_slots: make_chan(s.exchange.max_waiters),
        mailer: mailer_on(mail, s.email.from),
        settings: s,
        metrics: metrics.new_registry(),
        db: some(d),
        cache: some(c)
    });
}

pub fn publish_runtime_view(a: App, view: exchange.BookView) {
    mutex_lock(a.runtime_views_lock);
    let publish=true;
    if has(a.runtime_views,view.market_id) {
        let old_result:result[exchange.BookView,str]=json.decode(a.runtime_views[view.market_id]);
        if let old=old_result {
            publish=exchange.newer_view(old,view);
        } else let e=err_of(old_result) {
            metrics.add(a.metrics,"exchange_view_cache_errors_total",1);
        }
    }
    if publish { a.runtime_views[view.market_id]=json.encode(view); }
    mutex_unlock(a.runtime_views_lock);
}

fn invalidate_runtime_view(a: App, market_id: str) {
    mutex_lock(a.runtime_views_lock);
    if has(a.runtime_views,market_id) {
        let decoded:result[exchange.BookView,str]=json.decode(a.runtime_views[market_id]);
        if let view=decoded {
            view.health="DEGRADED";
            view.lease_until=0;
            a.runtime_views[market_id]=json.encode(view);
        } else let e=err_of(decoded) {
            a.settings.server.logger.warn("exchange","cached book-view invalidation failed for "+market_id+": "+e);
            metrics.add(a.metrics,"exchange_view_cache_errors_total",1);
        }
    }
    mutex_unlock(a.runtime_views_lock);
}

pub fn runtime_view(a: App, market_id: str) -> result[opt[exchange.BookView],str] {
    mutex_lock(a.runtime_views_lock);
    let encoded:opt[str]=none;
    if has(a.runtime_views,market_id) { encoded=some(a.runtime_views[market_id]); }
    mutex_unlock(a.runtime_views_lock);
    guard let payload=encoded else {
        let empty:opt[exchange.BookView]=none;
        return ok(empty);
    }
    let decoded:result[exchange.BookView,str]=json.decode(payload);
    guard let view=decoded else let e=err_of(decoded) { return err("runtime view decode: "+e); }
    if view.health!="READY" || view.lease_until<=time.wall()/1000000 {
        let empty:opt[exchange.BookView]=none;
        return ok(empty);
    }
    return ok(some(view));
}

pub fn exchange_policy(a: App, market_id: str) -> result[exchange.PolicyView,str] {
    let found=markets.get(a.markets,market_id,"");
    guard let market=found else let e=err_of(found) { return err(e.code); }
    let policy=markets.policy(a.markets,market_id);
    guard let value=policy else let e=err_of(policy) { return err(e.code); }
    return ok(exchange.policy_view(value,market.status,a.settings.exchange.slippage_ticks));
}

pub fn public_market_exists(a: App, market_id: str) -> result[bool,str] {
    let snapshot=markets.snapshot(a.markets);
    guard let data=snapshot else let e=err_of(snapshot) { return err(e.detail); }
    if let _market=markets.public_market(data,market_id) { return ok(true); }
    return ok(false);
}

pub fn get_portfolio_market_stats(a: App) -> map[str]portfolio_svc.MarketPriceStats {
    let out: map[str]portfolio_svc.MarketPriceStats = {};
    let snap_res = markets.snapshot(a.markets);
    guard let snap = snap_res else {
        return out;
    }
    for item in snap.stats {
        let has_last = false;
        let last_p = 0;
        if let lp = item.last_price {
            has_last = true;
            last_p = lp;
        }
        let has_bid = false;
        let bid = 0;
        if let b = item.yes_bid {
            has_bid = true;
            bid = b;
        }
        let has_ask = false;
        let ask = 0;
        if let k = item.yes_ask {
            has_ask = true;
            ask = k;
        }
        out[item.market_id] = portfolio_svc.MarketPriceStats {
            last_price: last_p,
            has_last_price: has_last,
            best_bid: bid,
            has_best_bid: has_bid,
            best_ask: ask,
            has_best_ask: has_ask
        };
    }
    return out;
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
    if len(token) >= 8 && strings.slice(token, 0, 8) == "say_bot_" {
        if let d = a.db {
            let h = encoding.hex_encode(crypto.sha256(to_bytes(token)));
            let lk = db.lookup_bot_key(d, h, until_of(time.mono() + 2000000000));
            if let found_opt = lk {
                if let bot_id = found_opt {
                    return ok(some(Caller { account_id: bot_id, session_hash: h }));
                }
            }
        }
        return ok(none_caller);
    }
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
        let legacy = db.publish_outbox(d, c, 100, a.settings.auth.pg_timeout_ns);
        let runtime = db.publish_runtime_outbox(d,c,a.node_id,100,a.settings.auth.pg_timeout_ns);
        let sent = 0;
        if let n=legacy {
            sent+=n;
        } else let e=err_of(legacy) {
            a.settings.server.logger.warn("outbox","legacy publish failed: "+e);
        }
        if let n=runtime {
            sent+=n;
        } else let e=err_of(runtime) {
            a.settings.server.logger.warn("outbox","runtime publish failed: "+e);
        }
        if sent>0 {
            metrics.add(a.metrics,"outbox_published_total",sent);
            continue;
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
    start_exchange_workers(a);
    spawn run_exchange_view_hydrator(a);
    spawn run_snapshot_writer(a);
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
    start_stream_workers(a);
    spawn run_closing_soon_scheduler(a);
    spawn run_resolution_watchers(a);
}

fn run_resolution_watchers(a: App) -> int {
    while true {
        time.sleep(10000000000); // 10s
        let _ = resolution_svc.tick_watchers(a.resolution);
    }
    return 0;
}

fn run_closing_soon_scheduler(a: App) -> int {
    while true {
        time.sleep(30000000000); // 30s
        let _ = notifications_svc.poll_closing_soon(a.notifications);
    }
    return 0;
}

fn run_exchange_view_hydrator(a: App) -> int {
    let after_market_id="";
    let last_error_at:duration=0;
    let known_ids:[str]=[];
    let known:map[str]bool={};
    let seen:map[str]bool={};
    while true {
        let loaded=exchange.ready_views(a.book_views,after_market_id,500);
        if let views=loaded {
            let scan_complete=len(views)<500;
            if scan_complete { after_market_id=""; }
            else { after_market_id=views[len(views)-1].market_id; }
            for view in views {
                if !has(known,view.market_id) {
                    known[view.market_id]=true;
                    push(known_ids,view.market_id);
                }
                seen[view.market_id]=true;
                let freshness_limit=view.as_of+a.settings.exchange.view_freshness_ms;
                if view.lease_until>freshness_limit { view.lease_until=freshness_limit; }
                publish_runtime_view(a,view);
            }
            if scan_complete {
                for market_id in known_ids {
                    if !has(seen,market_id) { invalidate_runtime_view(a,market_id); }
                }
                seen={};
            }
        } else let e=err_of(loaded) {
            let now=time.mono();
            if now-last_error_at>=5000000000 {
                a.settings.server.logger.warn("exchange","book-view hydration failed: "+e);
                metrics.add(a.metrics,"exchange_view_hydration_failures_total",1);
                last_error_at=now;
            }
        }
        time.sleep(500000000);
    }
    return 0;
}

fn run_snapshot_writer(a: App) -> int {
    while true {
        let received=chan_recv(a.snapshot_queue);
        guard let snapshot=received else { return 0; }
        let saved=a.recovery_store.save_snapshot(a.recovery_store.context,snapshot);
        if let inserted=saved {
            if !inserted { metrics.add(a.metrics,"exchange_snapshot_stale_total",1); }
            else { metrics.add(a.metrics,"exchange_snapshots_written_total",1); }
        } else let e=err_of(saved) {
            a.settings.server.logger.warn("exchange","snapshot write failed for "+snapshot.market_id+": "+e);
            metrics.add(a.metrics,"exchange_snapshot_write_failures_total",1);
        }
    }
    return 0;
}

fn queue_snapshot(a: App, actor: exchange.Actor[exchange_store.Postgres]) -> bool {
    let captured=exchange.snapshot_write(actor);
    guard let snapshot=captured else let e=err_of(captured) {
        a.settings.server.logger.warn("exchange","snapshot capture failed for "+actor.book.policy.market_id+": "+e);
        metrics.add(a.metrics,"exchange_snapshot_capture_failures_total",1);
        return false;
    }
    select {
        case chan_send(a.snapshot_queue,snapshot) { return true; }
        default {
            metrics.add(a.metrics,"exchange_snapshot_queue_drops_total",1);
            return false;
        }
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

pub fn start_stream_workers(a: App) {
    for s in 0..64 {
        spawn run_stream_shard_reader(a, s);
    }
    spawn run_stream_cards_ticker(a);
    spawn run_stream_session_revocations(a);
    spawn run_stream_session_rechecker(a);
}

fn run_stream_shard_reader(a: App, shard: int) -> int {
    let last_id = "$";
    while true {
        let now_ms = (time.mono() / 1000000) as int;
        let read_fn = a.stream.store.read_shard_stream;
        let read_res = read_fn(a.stream.store.context, shard, last_id, 1000, 100);
        if let msgs = read_res {
            for m in msgs {
                last_id = m.id;
                stream_svc.dispatch_private_event(a.stream.shards, m, now_ms);
            }
        } else {
            time.sleep(200000000);
        }
    }
    return 0;
}

fn run_stream_cards_ticker(a: App) -> int {
    while true {
        time.sleep(1000000000);
        let now_ms = (time.mono() / 1000000) as int;
        let stats_fn = a.stream.store.get_market_stats;
        let stats_res = stats_fn(a.stream.store.context);
        if let stats = stats_res {
            stream_svc.dispatch_cards_tick(a.stream.ticker, stats, now_ms);
        }
    }
    return 0;
}

fn run_stream_session_revocations(a: App) -> int {
    let last_id = "$";
    while true {
        let now_ms = (time.mono() / 1000000) as int;
        let read_fn = a.stream.store.read_session_revocations;
        let read_res = read_fn(a.stream.store.context, last_id, 1000, 100);
        if let sessions = read_res {
            for sess in sessions {
                last_id = sess.id;
                stream_svc.revoke_session(a.stream, sess.session_id, now_ms);
            }
        } else {
            time.sleep(500000000);
        }
    }
    return 0;
}

fn run_stream_session_rechecker(a: App) -> int {
    while true {
        time.sleep(300000000000);
        let sessions_to_check: [str] = [];
        mutex_lock(a.stream.conns_lock);
        for cid, c in a.stream.conns {
            if c.session_id != "" {
                push(sessions_to_check, c.session_id);
            }
        }
        mutex_unlock(a.stream.conns_lock);

        let now_ms = (time.mono() / 1000000) as int;
        for sess_id in sessions_to_check {
            let chk_fn = a.stream.store.is_session_valid;
            let chk = chk_fn(a.stream.store.context, sess_id);
            if let valid = chk {
                if !valid {
                    stream_svc.revoke_session(a.stream, sess_id, now_ms);
                }
            }
        }
    }
    return 0;
}

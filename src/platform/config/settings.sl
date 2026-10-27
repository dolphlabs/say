import "strings";
import "timez";
import "zokor";

pub gc struct AuthSettings {
    otp_secret: str,
    reserved_usernames: [str],
    hash_workers: int,
    hash_queue: int,
    google_client_id: str,
    google_client_secret: str,
    google_redirect_uri: str,
    google_auth_url: str,
    google_token_url: str,
    google_jwks_url: str,
    app_url: str,
    pg_timeout_ns: int,
    redis_timeout_ns: int,
    google_timeout_ns: int
}

pub gc struct EmailSettings {
    provider: str,
    sendbyte_api_key: str,
    sendbyte_url: str,
    from: str,
    timeout_ns: int
}

pub gc struct LedgerSettings {
    season_anchor: timez.Time,
    grant_workers: int,
    grant_chunk: int,
    recon_every_ns: int,
    metrics_token: str
}

pub gc struct MarketSettings {
    snapshot_every_ns: int,
    close_poll_ns: int,
    close_workers: int,
    history_generations: int
}

pub gc struct Settings {
    service_name: str,
    profile: str,
    port: int,
    server: zokor.ServerConfig,
    database_url: str,
    db_pool_size: int,
    redis_url: str,
    redis_pool_size: int,
    trading_fee: int,
    min_order_notional: int,
    dispute_window_seconds: int,
    timezone: str,
    auth: AuthSettings,
    email: EmailSettings,
    ledger: LedgerSettings,
    markets: MarketSettings
}

fn default_reserved() -> str {
    return "say,admin,administrator,support,sedi,sedis,root,help,official,mod,moderator,system," +
           "staff,team,security,api,www,mail,about,settings,login,signup,null,undefined";
}

fn list_of(raw: str) -> [str] {
    let out: [str] = [];
    for part in strings.split(raw, ",") {
        let p = strings.to_lower(strings.trim(part));
        if len(p) > 0 {
            push(out, p);
        }
    }
    return out;
}

fn note(cfg: zokor.Config, key: str, reason: str) {
    push(cfg.problems, zokor.Problem { key: key, reason: reason, shown: "" });
}

pub fn settings_from(cfg: zokor.Config) -> Settings {
    let sc = zokor.server_config_from(cfg);
    sc.request_ids = false;
    let profile = cfg.profile;
    if len(profile) == 0 {
        profile = "dev";
    }
    let dev = profile == "dev" || profile == "test";

    // The console sender prints codes; it exists for local work only.
    let fallback_provider = "sendbyte";
    if dev {
        fallback_provider = "console";
    }
    let provider = zokor.optional_one_of(cfg, "EMAIL_PROVIDER", ["sendbyte", "console"], fallback_provider);
    if provider == "console" && !dev {
        note(cfg, "EMAIL_PROVIDER", "console prints one-time codes and is allowed only in the dev and test profiles");
    }
    let sendbyte_key = zokor.str_or(cfg, "SENDBYTE_API_KEY", zokor.str_or(cfg, "SEND_BYTE_KEY", ""));
    if provider == "sendbyte" && len(sendbyte_key) < 8 {
        note(cfg, "SENDBYTE_API_KEY", "is required when EMAIL_PROVIDER is sendbyte");
    }

    let google_id = zokor.str_or(cfg, "GOOGLE_CLIENT_ID", "");
    let google_secret = zokor.str_or(cfg, "GOOGLE_CLIENT_SECRET", "");
    let google_redirect = zokor.optional_url(cfg, "GOOGLE_REDIRECT_URI", "");
    if len(google_id) > 0 && (len(google_secret) == 0 || len(google_redirect) == 0) {
        note(cfg, "GOOGLE_CLIENT_SECRET", "GOOGLE_CLIENT_SECRET and GOOGLE_REDIRECT_URI are required with GOOGLE_CLIENT_ID");
    }

    // Season 01 starts Mon 12 Oct 2026, 00:00 Africa/Lagos.
    let anchor_text = zokor.str_or(cfg, "SEASON_ANCHOR", "2026-10-11T23:00:00Z");
    let anchor = timez.unix(0);
    let ar = timez.parse_rfc3339(anchor_text);
    if let t = ar {
        anchor = t;
    } else let e = err_of(ar) {
        note(cfg, "SEASON_ANCHOR", "must be an RFC 3339 instant: " + e);
    }
    let workers = zokor.int_or(cfg, "GRANT_WORKERS", 4);
    if workers < 1 || workers > 32 {
        note(cfg, "GRANT_WORKERS", "must be 1-32");
    }
    let metrics_token = zokor.str_or(cfg, "METRICS_TOKEN", "");
    if len(metrics_token) > 0 && len(metrics_token) < 16 {
        note(cfg, "METRICS_TOKEN", "must be at least 16 characters, or unset to turn /metrics off");
    }
    let market_workers=zokor.int_or(cfg,"MARKET_CLOSE_WORKERS",8);
    let snapshot_every=zokor.duration_or(cfg,"MARKET_SNAPSHOT_EVERY",1800000000);
    let close_poll=zokor.duration_or(cfg,"MARKET_CLOSE_POLL",100000000);
    let generations=zokor.int_or(cfg,"MARKET_SNAPSHOT_GENERATIONS",32);
    if market_workers<1 || market_workers>32 { note(cfg,"MARKET_CLOSE_WORKERS","must be 1–32"); }
    if snapshot_every<100000000 || snapshot_every>2000000000 { note(cfg,"MARKET_SNAPSHOT_EVERY","must be 100ms–2s"); }
    if close_poll<10000000 || close_poll>1000000000 { note(cfg,"MARKET_CLOSE_POLL","must be 10ms–1s"); }
    if generations<2 || generations>128 { note(cfg,"MARKET_SNAPSHOT_GENERATIONS","must be 2–128"); }

    return Settings {
        service_name: zokor.str_or(cfg, "SERVICE_NAME", "say"),
        profile: profile,
        port: zokor.require_port(cfg, "PORT"),
        server: sc,
        database_url: zokor.optional_dsn(cfg, "DATABASE_URL", ""),
        db_pool_size: zokor.int_or(cfg, "DB_POOL_SIZE", 10),
        redis_url: zokor.optional_dsn(cfg, "REDIS_URL", ""),
        redis_pool_size: zokor.int_or(cfg, "REDIS_POOL_SIZE", 8),
        trading_fee: zokor.int_or(cfg, "TRADING_FEE", 1),
        min_order_notional: zokor.int_or(cfg, "MIN_ORDER_NOTIONAL", 2),
        dispute_window_seconds: zokor.int_or(cfg, "DISPUTE_WINDOW_SECONDS", 1800),
        timezone: zokor.str_or(cfg, "TIMEZONE", "Africa/Lagos"),
        auth: AuthSettings {
            otp_secret: zokor.require_min_len(cfg, "OTP_SECRET", 32),
            reserved_usernames: list_of(zokor.str_or(cfg, "RESERVED_USERNAMES", default_reserved())),
            hash_workers: zokor.int_or(cfg, "HASH_WORKERS", 2),
            hash_queue: zokor.int_or(cfg, "HASH_QUEUE", 64),
            google_client_id: google_id,
            google_client_secret: google_secret,
            google_redirect_uri: google_redirect,
            google_auth_url: zokor.optional_url(cfg, "GOOGLE_AUTH_URL", "https://accounts.google.com/o/oauth2/v2/auth"),
            google_token_url: zokor.optional_url(cfg, "GOOGLE_TOKEN_URL", "https://oauth2.googleapis.com/token"),
            google_jwks_url: zokor.optional_url(cfg, "GOOGLE_JWKS_URL", "https://www.googleapis.com/oauth2/v3/certs"),
            app_url: zokor.optional_url(cfg, "APP_URL", "http://localhost:3000"),
            pg_timeout_ns: zokor.duration_or(cfg, "PG_TIMEOUT", 2000000000),
            redis_timeout_ns: zokor.duration_or(cfg, "REDIS_TIMEOUT", 50000000),
            google_timeout_ns: zokor.duration_or(cfg, "GOOGLE_TIMEOUT", 5000000000)
        },
        email: EmailSettings {
            provider: provider,
            sendbyte_api_key: sendbyte_key,
            sendbyte_url: zokor.optional_url(cfg, "SENDBYTE_URL", "https://api.sendbyte.africa/v1/emails"),
            from: zokor.str_or(cfg, "EMAIL_FROM", "say <verify@say.exchange>"),
            timeout_ns: zokor.duration_or(cfg, "EMAIL_TIMEOUT", 10000000000)
        },
        ledger: LedgerSettings {
            season_anchor: anchor,
            grant_workers: workers,
            grant_chunk: zokor.int_or(cfg, "GRANT_CHUNK", 500),
            recon_every_ns: zokor.duration_or(cfg, "RECON_EVERY", 300000000000),
            metrics_token: metrics_token
        },
        markets: MarketSettings { snapshot_every_ns:snapshot_every,close_poll_ns:close_poll,close_workers:market_workers,history_generations:generations }
    };
}

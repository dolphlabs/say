import "zokor";

pub gc struct Settings {
    service_name: str,
    port: int,
    api_keys: zokor.ApiKeys,
    cookie_keys: zokor.CookieKeys,
    jwt_auth: zokor.JwtAuth,
    server: zokor.ServerConfig,
    database_url: str,
    db_pool_size: int,
    redis_url: str,
    redis_pool_size: int,
    trading_fee: int,
    min_order_notional: int,
    season_grant_amount: int,
    dispute_window_seconds: int,
    timezone: str
}

pub fn settings_from(cfg: zokor.Config) -> Settings {
    return Settings {
        service_name: zokor.str_or(cfg, "SERVICE_NAME", "say"),
        port: zokor.require_port(cfg, "PORT"),
        api_keys: zokor.api_keys_from(cfg),
        cookie_keys: zokor.cookie_keys_from(cfg),
        jwt_auth: zokor.jwt_auth_from(cfg),
        server: zokor.server_config_from(cfg),
        database_url: zokor.optional_dsn(cfg, "DATABASE_URL", ""),
        db_pool_size: zokor.int_or(cfg, "DB_POOL_SIZE", 10),
        redis_url: zokor.optional_dsn(cfg, "REDIS_URL", ""),
        redis_pool_size: zokor.int_or(cfg, "REDIS_POOL_SIZE", 8),
        trading_fee: zokor.int_or(cfg, "TRADING_FEE", 1),
        min_order_notional: zokor.int_or(cfg, "MIN_ORDER_NOTIONAL", 2),
        season_grant_amount: zokor.int_or(cfg, "SEASON_GRANT_AMOUNT", 1000),
        dispute_window_seconds: zokor.int_or(cfg, "DISPUTE_WINDOW_SECONDS", 1800),
        timezone: zokor.str_or(cfg, "TIMEZONE", "Africa/Lagos")
    };
}

import "zokor";

pub gc struct Settings {
    service_name: str,
    port: int,
    api_keys: zokor.ApiKeys,
    server: zokor.ServerConfig,
}

pub fn settings_from(cfg: zokor.Config) -> Settings {
    return Settings {
        service_name: zokor.str_or(cfg, "SERVICE_NAME", "say"),
        port: zokor.require_port(cfg, "PORT"),
        api_keys: zokor.api_keys_from(cfg),
        server: zokor.server_config_from(cfg)
    };
}

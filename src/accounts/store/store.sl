import "httpc";
import "pg";
import "redis";
import "../service" as service;

pub gc struct GoogleEndpoints {
    client_id: str,
    client_secret: str,
    token_url: str,
    jwks_url: str
}

// The adapters' shared state: Postgres is required, Redis optional (every
// ephemeral call fails over to the service's fallbacks without it).
pub gc struct Store {
    pg: pg.Pool,
    redis: opt[redis.Pool],
    http: httpc.Client,
    google: GoogleEndpoints,
    pg_timeout: int,
    redis_timeout: int,
    google_timeout: int
}

pub gc struct Timeouts {
    pg_ns: int,
    redis_ns: int,
    google_ns: int
}

pub fn new_store(pool: pg.Pool, cache: opt[redis.Pool], google: GoogleEndpoints, t: Timeouts) -> Store {
    return Store {
        pg: pool,
        redis: cache,
        http: httpc.new_client(),
        google: google,
        pg_timeout: t.pg_ns,
        redis_timeout: t.redis_ns,
        google_timeout: t.google_ns
    };
}

pub fn auth_store(s: Store) -> service.AuthStore[Store] {
    return service.AuthStore[Store] {
        context: s,
        usernames_taken: st_usernames_taken,
        create_signup: st_create_signup,
        replace_code: st_replace_code,
        signup_account: st_signup_account,
        issue_signup_token: st_issue_signup_token,
        verify_email: st_verify_email,
        reset_password: st_reset_password,
        find_login: st_find_login,
        set_password_hash: st_set_password_hash,
        create_session: st_create_session,
        session_lookup: st_session_lookup,
        revoke_session: st_revoke_session,
        revoke_others: st_revoke_others,
        touch_session: st_touch_session,
        account: st_account,
        password_hash_of: st_password_hash_of,
        change_password: st_change_password,
        unlink_google: st_unlink_google,
        delete_account: st_delete_account,
        identity_owner: st_identity_owner,
        email_owner: st_email_owner,
        create_google_account: st_create_google_account,
        link_google: st_link_google,
        insert_audit: st_insert_audit,
        claim_outbox: st_claim_outbox,
        outbox_sent: st_outbox_sent,
        outbox_retry: st_outbox_retry,
        sweep_expired: st_sweep_expired,
        eph_put_nx: st_eph_put_nx,
        eph_put: st_eph_put,
        eph_get: st_eph_get,
        eph_take: st_eph_take,
        eph_drop: st_eph_drop,
        eph_hit: st_eph_hit,
        google_exchange: st_google_exchange,
        google_jwks: st_google_jwks
    };
}

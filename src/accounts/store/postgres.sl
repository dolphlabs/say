import "pg";
import "time";
import "zokor";
import "../domain" as domain;
import "../service" as service;

pub gc struct Postgres {
    pool: pg.Pool,
    timeout: int
}

fn new_postgres(pool: pg.Pool) -> Postgres {
    return Postgres { pool: pool, timeout: 2000000000 };
}

fn deadline(p: Postgres) -> until {
    return until_of(time.mono() + p.timeout);
}

fn pg_insert(p: Postgres, n: domain.Account) -> result[bool, str] {
    let u_arg = pg.arg_null();
    if let u = n.username {
        u_arg = pg.arg_text(u);
    }
    let email_arg = pg.arg_null();
    if let em = n.email {
        email_arg = pg.arg_text(em);
    }
    let phone_arg = pg.arg_null();
    if let ph = n.phone_number {
        phone_arg = pg.arg_text(ph);
    }
    let pass_arg = pg.arg_null();
    if let pass = n.password_hash {
        pass_arg = pg.arg_text(pass);
    }
    let group_arg = pg.arg_null();
    if let bg = n.beneficial_owner_group {
        group_arg = pg.arg_text(bg);
    }
    let r: result[[domain.Account], str] = zokor.query_all(p.pool,
        "insert into accounts (id, username, email, phone_number, password_hash, auth_provider, status, kind, beneficial_owner_group) " +
        "values ($1, $2, $3, $4, $5, $6, $7, $8, $9) " +
        "returning id, username, email, phone_number, password_hash, auth_provider, status, kind, beneficial_owner_group, " +
        "email_verified_at::text, verified_at::text, age_confirmed_at::text, created_at::text",
        [pg.arg_text(n.id), u_arg, email_arg, phone_arg, pass_arg, pg.arg_text(n.auth_provider), pg.arg_text(n.status), pg.arg_text(n.kind), group_arg],
        deadline(p));
    guard let _rows = r else let e = err_of(r) {
        return err(e);
    }
    return ok(true);
}

fn pg_find(p: Postgres, tenant_id: str, id: str) -> result[opt[domain.Account], str] {
    return zokor.query_one(p.pool,
        "select id, username, email, phone_number, password_hash, auth_provider, status, kind, beneficial_owner_group, " +
        "email_verified_at::text, verified_at::text, age_confirmed_at::text, created_at::text " +
        "from accounts where id = $1",
        [pg.arg_text(id)], deadline(p));
}

fn pg_find_by_username(p: Postgres, tenant_id: str, username: str) -> result[opt[domain.Account], str] {
    return zokor.query_one(p.pool,
        "select id, username, email, phone_number, password_hash, auth_provider, status, kind, beneficial_owner_group, " +
        "email_verified_at::text, verified_at::text, age_confirmed_at::text, created_at::text " +
        "from accounts where lower(username) = lower($1)",
        [pg.arg_text(username)], deadline(p));
}

fn pg_find_by_email(p: Postgres, tenant_id: str, email: str) -> result[opt[domain.Account], str] {
    return zokor.query_one(p.pool,
        "select id, username, email, phone_number, password_hash, auth_provider, status, kind, beneficial_owner_group, " +
        "email_verified_at::text, verified_at::text, age_confirmed_at::text, created_at::text " +
        "from accounts where lower(email) = lower($1)",
        [pg.arg_text(email)], deadline(p));
}

fn pg_find_by_phone(p: Postgres, tenant_id: str, phone: str) -> result[opt[domain.Account], str] {
    return zokor.query_one(p.pool,
        "select id, username, email, phone_number, password_hash, auth_provider, status, kind, beneficial_owner_group, " +
        "email_verified_at::text, verified_at::text, age_confirmed_at::text, created_at::text " +
        "from accounts where phone_number = $1",
        [pg.arg_text(phone)], deadline(p));
}

fn pg_list(p: Postgres, tenant_id: str, offset: int, limit: int) -> result[[domain.Account], str] {
    return zokor.query_all(p.pool,
        "select id, username, email, phone_number, password_hash, auth_provider, status, kind, beneficial_owner_group, " +
        "email_verified_at::text, verified_at::text, age_confirmed_at::text, created_at::text " +
        "from accounts order by created_at, id offset $1 limit $2",
        [pg.arg_int(offset), pg.arg_int(limit)], deadline(p));
}

gc struct AuditJob {
    pool: pg.Pool,
    account_id: str,
    action: str,
    ip_address: opt[str],
    user_agent: opt[str],
    fingerprint: opt[str],
    detail_json: str,
    timeout: int
}

fn async_pg_record_audit(job: AuditJob) {
    let dl = until_of(time.mono() + job.timeout);
    let ip_arg = pg.arg_null();
    if let ip = job.ip_address {
        ip_arg = pg.arg_text(ip);
    }
    let ua_arg = pg.arg_null();
    if let ua = job.user_agent {
        ua_arg = pg.arg_text(ua);
    }
    let fp_arg = pg.arg_null();
    if let fp = job.fingerprint {
        fp_arg = pg.arg_text(fp);
    }

    let _d = pg.pool_query(job.pool,
        "insert into account_devices (account_id, ip_address, user_agent, fingerprint) " +
        "values ($1, case when $2 ~ '^[0-9a-fA-F.:]+$' then $2::inet else null end, $3, $4)",
        [pg.arg_text(job.account_id), ip_arg, ua_arg, fp_arg], dl);

    let _a = pg.pool_query(job.pool,
        "insert into audit_events (actor_id, action, target_type, target_id, ip_address, user_agent, detail) " +
        "values ($1, $2, 'ACCOUNT', $1, case when $3 ~ '^[0-9a-fA-F.:]+$' then $3::inet else null end, $4, $5::jsonb)",
        [pg.arg_text(job.account_id), pg.arg_text(job.action), ip_arg, ua_arg, pg.arg_text(job.detail_json)], dl);
}

fn pg_record_signup_audit(p: Postgres, tenant_id: str, account_id: str, meta: service.AuditMeta) -> result[bool, str] {
    let job = AuditJob {
        pool: p.pool,
        account_id: account_id,
        action: "ACCOUNT_REGISTER",
        ip_address: meta.ip_address,
        user_agent: meta.user_agent,
        fingerprint: meta.fingerprint,
        detail_json: meta.detail_json,
        timeout: p.timeout
    };
    spawn async_pg_record_audit(job);
    return ok(true);
}

fn pg_record_login_audit(p: Postgres, tenant_id: str, account_id: str, meta: service.AuditMeta) -> result[bool, str] {
    let job = AuditJob {
        pool: p.pool,
        account_id: account_id,
        action: "ACCOUNT_LOGIN",
        ip_address: meta.ip_address,
        user_agent: meta.user_agent,
        fingerprint: meta.fingerprint,
        detail_json: meta.detail_json,
        timeout: p.timeout
    };
    spawn async_pg_record_audit(job);
    return ok(true);
}

fn pg_verify_email(p: Postgres, tenant_id: str, email: str) -> result[bool, str] {
    let r = pg.pool_query(p.pool,
        "update accounts set email_verified_at = coalesce(email_verified_at, now()), verified_at = coalesce(verified_at, now()) where lower(email) = lower($1)",
        [pg.arg_text(email)], deadline(p));
    guard let _rows = r else let e = err_of(r) {
        return err(e);
    }
    return ok(true);
}

fn pg_confirm_age(p: Postgres, tenant_id: str, account_id: str) -> result[bool, str] {
    let r = pg.pool_query(p.pool,
        "update accounts set age_confirmed_at = coalesce(age_confirmed_at, now()) where id = $1",
        [pg.arg_text(account_id)], deadline(p));
    guard let _rows = r else let e = err_of(r) {
        return err(e);
    }
    return ok(true);
}

import "pg";
import "time";
import "zokor";
import "../domain" as domain;

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
    let email_arg = pg.arg_null();
    if let em = n.email {
        email_arg = pg.arg_text(em);
    }
    let pass_arg = pg.arg_null();
    if let ph = n.password_hash {
        pass_arg = pg.arg_text(ph);
    }
    let group_arg = pg.arg_null();
    if let bg = n.beneficial_owner_group {
        group_arg = pg.arg_text(bg);
    }
    let r: result[[domain.Account], str] = zokor.query_all(p.pool,
        "insert into accounts (id, email, password_hash, auth_provider, status, kind, beneficial_owner_group) " +
        "values ($1, $2, $3, $4, $5, $6, $7) " +
        "returning id, email, password_hash, auth_provider, status, kind, beneficial_owner_group, " +
        "email_verified_at::text, verified_at::text, age_confirmed_at::text, created_at::text",
        [pg.arg_text(n.id), email_arg, pass_arg, pg.arg_text(n.auth_provider), pg.arg_text(n.status), pg.arg_text(n.kind), group_arg],
        deadline(p));
    guard let _rows = r else let e = err_of(r) {
        return err(e);
    }
    return ok(true);
}

fn pg_find(p: Postgres, tenant_id: str, id: str) -> result[opt[domain.Account], str] {
    return zokor.query_one(p.pool,
        "select id, email, password_hash, auth_provider, status, kind, beneficial_owner_group, " +
        "email_verified_at::text, verified_at::text, age_confirmed_at::text, created_at::text " +
        "from accounts where id = $1",
        [pg.arg_text(id)], deadline(p));
}

fn pg_find_by_email(p: Postgres, tenant_id: str, email: str) -> result[opt[domain.Account], str] {
    return zokor.query_one(p.pool,
        "select id, email, password_hash, auth_provider, status, kind, beneficial_owner_group, " +
        "email_verified_at::text, verified_at::text, age_confirmed_at::text, created_at::text " +
        "from accounts where email = $1",
        [pg.arg_text(email)], deadline(p));
}

fn pg_list(p: Postgres, tenant_id: str, offset: int, limit: int) -> result[[domain.Account], str] {
    return zokor.query_all(p.pool,
        "select id, email, password_hash, auth_provider, status, kind, beneficial_owner_group, " +
        "email_verified_at::text, verified_at::text, age_confirmed_at::text, created_at::text " +
        "from accounts order by created_at, id offset $1 limit $2",
        [pg.arg_int(offset), pg.arg_int(limit)], deadline(p));
}

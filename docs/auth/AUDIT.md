# Auth audit: existing signup, login, logout

Audited at `d725735` (2026-10-19). Scope: `src/accounts/**`,
`src/platform/{auth,app,cache,email}`, and `migrations/001`–`002`.
Status is **pass**, **fail** or **missing**. Every fix is folded into
[PLAN.md](PLAN.md).

## Summary

The basics are sound: argon2id with a per-password salt, constant-time
comparison, parameterised SQL, HttpOnly/Secure/Lax cookies, and a
revocation check on logout. What is wrong is structural. Hashing runs
inline on scheduler workers. Sessions are stateless JWTs and nothing is
stored hashed. The verification code is weak and not bounded. Login leaks
whether an account exists, both by its error and by its timing. There is
no rate limiting. The account endpoints are public, including listing
every user's email and phone number.

## Findings

| # | Check | Status | Where | Fix |
|---|---|---|---|---|
| 1 | Password storage: algorithm and salt | **pass** | `service/password.sl:10-23` | argon2id with a 16-byte salt from `crypto.rand`, 32-byte tag. Keep it. |
| 2 | Password hash format | **fail** | `service/password.sl:22` | Hex salt and tag in a PHC-like string: not standard PHC, with params hard-coded in verify (`:41`), so costs can never change. Use standard PHC (base64, params parsed from the string) and rehash on login when params differ. |
| 3 | Password cost | **fail** (minor) | `service/password.sl:16` | m=64 MiB, t=1. That is a lot of memory per concurrent hash (see 5). Move to OWASP m=19 MiB, t=2, p=1, set in config. |
| 4 | Constant-time compare | **pass** | `service/password.sl:41` | `crypto.argon2id_verify` compares inside OpenSSL's runtime. Token and OTP comparisons will use `zokor.constant_time_equal`. |
| 5 | Hashing blocks the scheduler | **fail** | `service/service.sl:101`, `:253` | Inline in the request task. argon2 runs with preemption off (`slang/runtime/sl_crypto.c`), so every concurrent login pins a whole OS worker; with ≥ N logins on N workers, the process stops serving everything else. Fix: a bounded hashing pool of K < workers tasks with a bounded queue, and 503 + `retry_after` when it is full. |
| 6 | Email normalisation | **fail** | `service/service.sl:52-70` (signup), `:215` (login) | Login trims and lowercases; signup stores the email exactly as typed. Normalise once in `domain/` and use it everywhere. |
| 7 | Field length limits | **fail** (partial) | `domain/account.sl:80-87`, `server/server.sl:114` | Password capped at 128, email at 255. **Login** has no cap (`service.sl:219`), so a 16 KiB password (the server's body limit) gets hashed. Cap every field in the DTO check, before any hash. |
| 8 | Password minimum 8 | **pass** | `domain/account.sl:82` | The composition rules (upper, lower, digit, special) go beyond the spec. Replace them with length plus a strength score that the UI's bar can mirror. |
| 9 | Username rules | **fail** | `domain/account.sl:60-78` | 3–10 characters, mixed case, no `.`. The spec is lowercase `^[a-z0-9][a-z0-9._]{1,18}[a-z0-9_]$` plus a reserved list. |
| 10 | Unique email, case-insensitive | **fail** | `migrations/001:22`, `:34` | `email text UNIQUE` is case-sensitive, so `Joe@x` and `joe@x` can both exist. Lookups use `lower(email)`, which that index does not serve. Use `citext` with a unique constraint. |
| 11 | Unique username, case-insensitive | **pass** (partial) | `migrations/002:7-9` | A unique index on `lower(username)` exists, but the column is nullable. The spec makes it `citext NOT NULL`. |
| 12 | DB constraint is the final guard | **fail** | `service/service.sl:72-99`, `store/postgres.sl:20-52` | Pre-checks with find-by, then insert. A race loses to the constraint, but the error comes back as `Unavailable`/503, not `USERNAME_TAKEN`/`EMAIL_IN_USE`. Map SQLSTATE 23505 by constraint name. |
| 13 | Parameterised SQL | **pass** | `store/postgres.sl` | Every query uses `$N`, and `zokor check` passes `sql`. |
| 14 | Atomic account creation | **fail** | `service/service.sl:124-133`, `server/server.sl:126-127` | The insert is one statement. The code is saved to Redis **after** the account exists, with the result discarded (`_saved`), so a Redis error leaves an account that cannot be verified, behind a 201. Code, outbox row and account belong in one transaction. |
| 15 | Session token generation | **fail** | `platform/auth/auth.sl:36-61` | A stateless HS256 JWT. The `jti` is 128 bits, but its fallback is `"jti_" + time` (`:20-26`). Use an opaque 32-byte CSPRNG token. |
| 16 | Session stored hashed | **missing** | — | Nothing is stored server-side; the JWT itself is the credential. The spec wants `sessions` with `sha256(token)`. |
| 17 | Server-side revocation | **fail** (partial) | `platform/app/app.sl:81-109`, `server/server.sl:156-171` | Logout writes `auth:revoked:{jti}` to Redis. With Redis down, `is_session_revoked` returns **false**, so revoked sessions work again. Log-out-everywhere is impossible with JWTs. Postgres must be the authority. |
| 18 | Expiry | **pass** (partial) | `platform/auth/auth.sl:38` | 7 days; the spec is 30, stored in `expires_at`. |
| 19 | Cookie flags | **pass** | `platform/auth/auth.sl:56-59` | HttpOnly, SameSite=Lax, and Secure (zokor's default). |
| 20 | Key rotation | **fail** | `platform/auth/auth.sl:87` | Verifies with `keys[0]` only, so rotating `JWT_SECRETS` logs everyone out. This goes away with opaque tokens. |
| 21 | Login error does not reveal the account | **fail** | `service/service.sl:245-247` | A suspended account answers `accounts.suspended` / 403 **before** the password is checked. Anyone can probe an email or username for existence and status. Check status only after a correct password. |
| 22 | Login timing | **fail** | `service/service.sl:241-243` | Unknown user returns at once; a known user costs one argon2. Run a dummy verify against a fixed hash on every not-found path. |
| 23 | Login identifier | note | `service/service.sl:233-236` | Login quietly also accepts a username in `email`. The spec says email. Drop it, or confirm it is wanted. |
| 24 | Rate limiting | **missing** | `server/server.sl:12-23` | None on signup, login, verify or username check. |
| 25 | Verification code strength | **fail** | `server/server.sl:106-112`, `platform/app/app.sl:57-79` | 8 hex characters (32 bits), valid 1 h, **no attempt limit**, stored in plain text in Redis as `auth:verify:{code}`, and keyed by the code alone. The CSPRNG fallback is the constant `"1A2B3C4D"`. Spec: 6 digits, HMAC-stored in Postgres, 10 min, 5 attempts, single-use in a transaction. |
| 26 | Code consumed atomically | **fail** | `server/server.sl:183-195` | GET then DELETE in Redis, two round trips, so concurrent verifies can all pass. Harmless today; with the S 1,000 grant it is a race. |
| 27 | Code purpose | **missing** | — | One namespace, with no purpose separating `verify_email` from `reset_password`. |
| 28 | OTP resend and cooldown | **missing** | — | No resend endpoint, cooldown or hourly cap. |
| 29 | Email delivery reliability | **fail** | `platform/app/app.sl:111-143` | Fire-and-forget `spawn` with the result discarded. A provider error loses the code with no retry, and nothing durable records that it was owed. Use an outbox row plus a worker. |
| 30 | Audit logging | **fail** | `store/postgres.sl:105-172`, `service/service.sl:131`, `:262` | One unbounded `spawn` per event, each taking a pool connection (a login flood doubles DB pool demand), as two separate inserts with no transaction, and both results discarded (`postgres.sl:120`, `:125`). Use a bounded channel, a single batching writer, and drop-and-count when full. |
| 31 | Authorisation on account reads | **fail** (severe) | `server/server.sl:1` (`// zokor:public`), `:21-22`, `:224-243` | `GET /v1/accounts` and `/v1/accounts/:id` are public and return email and phone. Remove them, replaced by `GET /v1/me`. |
| 32 | Client-supplied tenant | **fail** | `server/server.sl:26-36` | `x-tenant-id` header, else `"default"`. Removal is planned (see PLAN, decision D6). |
| 33 | Predictable fallbacks | **fail** | `platform/app/app.sl:14-18` | `new_uuid` returns all zeros when `crypto.rand` fails, so a second failure is a PK collision. Fail the request instead. |
| 34 | Login cookie failure | **fail** | `server/server.sl:146-153`, `:202-209` | If issuing the session fails, the handler still answers 200 with no session. Answer 503. |
| 35 | Logging secrets | **pass** (partial) | `platform/email/email.sl:78`, `server/errors.sl:43` | No password, token or code reaches a log. But the dev email path prints the recipient's address, and `errors.sl:43` logs raw store errors, where pg duplicate-key messages contain the email. Log the SQLSTATE and constraint name, not the detail. |
| 36 | External call timeouts | **pass** (partial) | `platform/email/email.sl:105` (10 s), `platform/cache/cache.sl` (2 s) | Redis has a 2 s deadline (the spec says 50 ms). Postgres calls in `store/postgres.sl` take deadlines; they should come from config. |
| 36b | Client IP source | **fail** | `server/server.sl:38-50` | Taken from raw `X-Forwarded-For`/`X-Real-IP`, which any client can set. As a rate-limit key it would be bypassable. Use `c.client_ip`, which honours `TRUSTED_PROXIES`. |
| 37 | Tests: what exists | — | `src/**/*_test.sl` (39 tests) | Domain validation, password round-trip, the service against fakes, HTTP flows on the in-memory store, cookie flags and revocation. Postgres store tests skip without `TEST_DATABASE_URL`. |
| 38 | Tests: what is missing | **missing** | — | Any concurrency test (duplicate signup race, parallel verify), any failure test (Redis down, provider down), timing equality, rate limits, lockout after N attempts, and a CI database (no docker-compose). |

## Schema facts that shape the plan

- `accounts.status` is `ACTIVE|SUSPENDED|LOCKED`, while the spec wants
  `unverified|active|deleted`. `accounts.kind` includes system accounts
  (`ISSUANCE`, `TREASURY` ...), which have no username, which conflicts
  with `username NOT NULL`.
- `wallets.free_units` has `CHECK (free_units >= 0)`, so **the issuance
  account's wallet can never be debited**, and the grant's balanced pair
  (issuance −1000, user +1000) cannot be posted.
- `auth_otps` exists (001:52) but is unused, with no attempts column or
  HMAC. `account_devices` exists and is written by the audit path.
- `seasons`, `wallets`, `ledger_transactions`, `ledger_entries` and
  `issuance_grants` exist with no seasons seeded. The sum-zero trigger is
  deferred, which is correct.
- Migrations are forward-only and checksummed (`zokor.migrate`), so
  every change goes in `003+`.

# Auth plan

The implementation plan for Prompt 01. It builds on
[AUDIT.md](AUDIT.md) and [slang-notes.md](slang-notes.md). **Implemented.**
The decisions below were settled on 2026-10-19: D1 and D2 as recommended
(in slang), D3 with argon v0.1.0, D4 by relaxing `zokor check` (so no SQL
function was needed), D5 as recommended, D6 opt-in rules in zokor_cli,
D7 with verify-age dropped entirely, D8 with the dev database reset. What
was built, and how it differs, is in [ASSUMPTIONS.md](ASSUMPTIONS.md).

## Decisions needed

| # | Decision | Recommendation |
|---|---|---|
| **D1** | Google ID-token signatures. slang has no RSA, and the `jwt` package is HS256 only, so JWKS verification cannot be written in say today. | **Add `crypto.rsa_verify_pkcs1_sha256(n, e, msg, sig)` to slang's runtime** (OpenSSL `EVP_DigestVerify`, ~80 lines of C plus a signature entry and tests) as a separate slang PR, and pin say to that release. If you would rather not touch slang now: OIDC Core §3.1.3.7 allows trusting an ID token received **directly from Google's token endpoint over TLS** without checking its signature, still checking `iss`, `aud`, `exp`, `nonce` and `email_verified`. I would build that path first and add the signature check when the RSA call lands. The JWKS refresher gets built either way. |
| **D2** | argon2 pins a worker with preemption off and delays every GC pause while it runs. | The say-side fix is the hashing pool (K < workers). The full fix is a small slang runtime change: mark the thread GC-blocked around `EVP_KDF_derive`. **Same separate slang PR as D1.** |
| **D3** | Password hashing library | Use `../slangpackages/argon` (standard PHC, bounded params, `needs_rehash`). It needs a **`v0.1.0` tag** to be pinned. The alternative is to keep `crypto.argon2id_*` and write PHC encoding in say. Either way, existing hex-format hashes still verify and are rehashed on next login. |
| **D4** | Atomic grant across features. `zokor check` only allows cross-feature imports `service → service`, a store cannot import another feature, and only `store/` and `platform/db` may import `pg`. So `accounts/store` cannot call `ledger/store` inside its transaction, and `platform/app` cannot wire a `pg.Conn`-typed adapter. | **The ledger feature owns a SQL function, `ledger_post_signup_grant(account_id, amount)`**, created in its migration. It finds the active season, creates the wallets, inserts the `ledger_transactions` row, two entries and `issuance_grants`, and returns `(amount, season_ordinal, season_ends_at)`, or no row when no season is active. `accounts/store` calls it inside the verify (or Google-complete) transaction. The database function is the contract between the two features, which keeps ownership clear and stays within `zokor check`. The alternative is to relax `zokor check` so one store may call another feature's store. |
| **D5** | The issuance wallet cannot go negative (`wallets.free_units >= 0`), so the grant cannot be balanced. | Migration: add `wallets.allow_negative boolean NOT NULL DEFAULT false` and replace the check with `CHECK (allow_negative OR free_units >= 0)`. Seed one `kind='ISSUANCE'` system account; its per-season wallet gets `allow_negative = true`. |
| **D6** | Tenant removal. `zokor check`'s `tenant` and `auth` rules cannot be switched off. | Remove it now, since auth is being rewritten anyway: drop `tenant_id` from every use case and store call, rename `require_tenant` to `require_session`, and add an opt-out to `zokor_cli` (a `zokor.rules` file listing disabled rules, e.g. `-tenant`) as a small zokor_cli PR. The other option is to keep `tenant_id: str` as a constant `"say"` until later. |
| **D7** | Existing endpoints not in the spec: `POST /v1/accounts/verify-age`, `GET /v1/accounts`, `GET /v1/accounts/:id`, and phone number at signup. | Remove the two GETs (finding 31). Keep the `age_confirmed_at` column, and move verify-age to `POST /v1/me/confirm-age` unless you want it gone. Keep the `phone_number` column but drop it from signup. |
| **D8** | Dev and test data | Migrations stay forward-only (`003+`). Existing dev accounts get lowercased usernames and emails, and are marked `active` if `email_verified_at` is set, else `unverified`. If the dev DB can simply be reset, say so and the data step goes away. |

## Layout

```
src/accounts/                      identity: accounts, credentials, identities,
  domain/   username.sl              regex, normalise, reserved, suggestions
            password_policy.sl       length 8-128, strength score
            otp.sl                   6-digit generation, HMAC, attempts rule
            linking.sl               google_link_policy(): the one function for D-GOOGLE
            account.sl               Account, status transitions, masking
  service/  ports.sl                 AccountStore, SessionStore, OtpStore, Outbox,
                                     HoldStore, RateLimits, EmailSender, Clock
            hasher.sl                bounded hashing pool (spawn + chan + select default)
            signup.sl / login.sl / otp.sl / sessions.sl / google.sl / me.sl
  store/    postgres.sl              all SQL; verify tx calls ledger_post_signup_grant()
            redis.sl                 holds, session cache, rate limits, pending_google, oauth state
            memory.sl                in-memory versions for unit tests
  server/   server.sl                /v1/auth/* (// zokor:public) and /v1/me/* (behind require_session)
            dto.sl, errors.sl
src/ledger/                        seasons, wallets, ledger, grants (read side, plus the SQL function)
  domain/   season.sl                current-season rules, Lagos display
  service/  ...                      current_season
  store/    postgres.sl
  server/   server.sl                GET /v1/seasons/current (needed by the load test)
src/platform/
  auth/     require_session          session cookie or Bearer, then cache, then Postgres
  email/    EmailSender: console (dev only, refuses in prod), SendByte adapter
```

The background tasks (outbox drainer, audit logger, JWKS refresher,
cleanup) live in `accounts/service/workers.sl` and drive the ports;
`platform/app` builds them and `main.sl` starts them before
`listen_and_serve`. They can't go in `platform/`, because only
`platform/app` may import a feature.

The Google HTTP calls (token exchange, JWKS fetch) live in
`accounts/store/google.sl` behind a port, because `httpc` is I/O.

## Data: migration 003_auth.sql

- `CREATE EXTENSION citext`. On `accounts`: `username` and `email`
  become `citext`, with unique constraints replacing
  `idx_accounts_username_lower` and `email UNIQUE`. Add
  `CHECK (kind <> 'USER' OR username IS NOT NULL)`, since system
  accounts have no username.
- `accounts.status`: `UNVERIFIED | ACTIVE | SUSPENDED | LOCKED |
  DELETED`, keeping the existing uppercase style. Add `deleted_at` and
  `username_changeable_at`.
- Move `password_hash` into `password_credentials(account_id pk, hash,
  algo, params, updated_at)` and drop the old column.
- New tables:
  - `auth_identities(provider, subject, account_id, email_at_link, linked_at)`, primary key `(provider, subject)`, unique `(account_id, provider)`.
  - `sessions(id, account_id, token_hash bytea unique, created_at, last_seen_at, expires_at, revoked_at, ip inet, user_agent)`, indexed on `(account_id) WHERE revoked_at IS NULL`.
  - `otp_codes(id, account_id, purpose, code_hmac bytea, expires_at, attempts, consumed_at, created_at)`, with a partial unique index on `(account_id, purpose) WHERE consumed_at IS NULL`. Drop the unused `auth_otps`.
  - `otp_sends(email citext, sent_at)` for the hourly cap.
  - `signup_tokens(token_hash pk, account_id, expires_at)`.
  - `auth_outbox(id, kind, payload jsonb, attempts, next_attempt_at, sent_at, created_at)`, indexed on `(next_attempt_at) WHERE sent_at IS NULL`.
- Ledger (D4, D5): `wallets.allow_negative`, the ISSUANCE system
  account, the `ledger_post_signup_grant` function, and an index
  `seasons(status) WHERE status = 'ACTIVE'`.

## Request flows

- **Signup (`POST /v1/auth/signup`)**: rate-limit by IP, then validate
  every field at once, then check the hold (`username:hold:{name}` must
  equal `hold_id`), then hash on the pool, then one transaction: insert
  the account (UNVERIFIED), the credential, the OTP (HMAC), the signup
  token (sha256), the `otp_sends` row and the outbox row. A 23505 maps
  by constraint name to `USERNAME_TAKEN` / `EMAIL_IN_USE`. After commit:
  `spawn` delivery, release the hold, and answer 201.
- **Verify (`POST /v1/auth/otp/verify`)**: one transaction with `SELECT
  ... FOR UPDATE` on the live OTP row. Check expiry and attempts, then
  compare the HMAC in constant time. A wrong code increments `attempts`
  and commits, answering `OTP_INVALID` with `attempts_left`, or
  `OTP_LOCKED` at 5. On a match: mark it consumed, set the account
  ACTIVE and `email_verified_at`, call `ledger_post_signup_grant`,
  insert the session, and delete the signup token. Twenty parallel
  verifies serialise on the row lock: one wins, the rest see
  `consumed_at` and get `OTP_INVALID`. The grant is protected twice
  more, by the `issuance_grants` primary key and the unique
  `business_key`.
- **Login**: rate-limit by email and by IP, then look the account up. If
  it is missing, verify against a fixed dummy hash on the pool (same
  cost). If the password is wrong, or the status is SUSPENDED, LOCKED or
  DELETED, answer `INVALID_CREDENTIALS`, the same for all of them. If
  UNVERIFIED with a correct password, answer `EMAIL_NOT_VERIFIED` with a
  fresh signup token. Otherwise rehash if needed, create the session,
  and set the cookie.
- **Sessions**: a 32-byte `crypto.rand` token, base64url for the client,
  `sha256` stored. `require_session` reads the cookie or Bearer token,
  then Redis `session:{hash}` (50 ms deadline), then Postgres on a miss
  or error, refilling Redis with a TTL of at most the remaining expiry.
  Revocation sets `revoked_at` first, then deletes the Redis key.
  `last_seen_at` is spawned at most once per 5 min (`SET NX EX 300`).
- **Google**: `start` stores `{state → nonce, verifier, intent}` in
  Redis for 10 min and redirects with S256 PKCE. `callback` uses `GETDEL`
  on the state (single use), exchanges the code (5 s), verifies the
  token per D1, then branches:
  - an identity exists: log in;
  - the email is used by a password account: `google_link_policy()`
    returns `GOOGLE_EMAIL_IN_USE`;
  - otherwise: `pending_google:{token}` for 15 min, then redirect to
    the username screen.

  `complete` runs one transaction: account (ACTIVE, verified), identity,
  grant, session. `intent=link` requires a session and attaches the
  identity.

## Concurrency

| Work | How |
|---|---|
| Password hash/verify | Pool of `HASH_WORKERS` tasks with a `chan` of `HASH_QUEUE` capacity, each job with a reply chan. A full queue gives 503 `RATE_LIMITED`-style `retry_after: 1`. |
| OTP email | Outbox row in the transaction, then `spawn deliver(id)` after commit, plus a drainer task every 5 s with backoff `min(2^attempts, 3600)` s. A row is claimed with `FOR UPDATE SKIP LOCKED`, so the spawn and the drainer never double-send. |
| Audit events | `chan[AuditEvent]` (capacity 4096). Sends use `select … default` and drop plus count when full. One writer batches every 250 ms or 100 events into a multi-row INSERT. |
| `last_seen_at` | Spawned, gated by Redis `SET NX EX 300`. |
| JWKS | One task holds the keys under a mutex and refreshes on `max-age`. An unknown `kid` triggers at most one refresh per 60 s. |
| Cleanup | `zokor.new_jobs` cron every 10 min deletes expired OTPs, signup tokens and sessions. |
| Username check | `spawn` the suggestions query and `join_wait` it alongside the pure checks. Validity and the reserved list are pure and microseconds, so only the DB query is worth spawning. |
| `GET /v1/me` | `spawn` the account+identities query and the season query, then `join_wait` both. |
| Timeouts | From config: Google 5 s, email 10 s, Redis 50 ms, Postgres 2 s (a client deadline that also sends a server-side cancel). |
| Rate limits | Redis `INCR` plus `EXPIRE` in MULTI/EXEC, keyed `rl:{rule}:{ip|email}`, with the IP from `c.client_ip`. On a Redis error, fall back to an in-process `zokor.RateLimiter` per rule and log `WARN` once per minute. |

## Errors

`zokor.set_renderer` produces `{error:{code,message,retry_after?}}` and
also adds `attempts_left` for `OTP_INVALID`. Every code in the spec is
registered in `accounts/server/errors.sl`, upper-case as the UI expects.
That differs from zokor's lower-case built-ins (`validation_failed`,
`rate_limited`, `unauthorized`), so the renderer maps those to
`*_INVALID` / `RATE_LIMITED` / `UNAUTHENTICATED`. Field validation is
reported as the first failing field's spec code (`EMAIL_INVALID`,
`WEAK_PASSWORD` ...).

## Tests

- **Unit** (no I/O, run in `make test`): username regex,
  normalisation, reserved list and suggestions; the password policy;
  OTP generation, HMAC and the attempts rule; `google_link_policy`; the
  hasher pool (bounded and rejecting, using a stub hash function); the
  audit batching logger (flushes at 100 and at 250 ms, drops when full);
  rate-limit fallback.
- **Integration**: a `docker-compose.test.yml` with Postgres 16 and
  Redis 7. Tests are gated on `TEST_DATABASE_URL` / `TEST_REDIS_URL`, as
  the existing pg tests are; `make test-integration` brings the stack
  up. They cover all the flows in spec §6, including the stubbed Google
  (a local token endpoint and JWKS served by a test router, signed with
  a test key, which needs D1 for the signature part).
- **Concurrency and failure**: the §6 list. "Redis down" means pointing
  at a closed port; "provider down" means a sender returning errors, then
  recovering.
- **Load**: `wrk` (installed) plus a Lua script for 500 concurrent
  logins, while a second `wrk` hits `GET /v1/seasons/current`. Report
  p50/p95/p99 for both, run with `SLANG_WORKERS` at the default (8 on
  this machine) and `HASH_WORKERS=4`. Docker is installed but not
  running right now.

## Order of work (one commit each)

1. Migration 003 plus the `ledger` SQL function and seed. *(Needs D4, D5, D8.)*
2. `accounts/domain`: username, password policy, OTP, linking policy, with unit tests.
3. Hashing pool, audit logger and outbox worker, with unit tests.
4. Sessions and `require_session` (cache + Postgres), with the old JWT path removed.
5. Signup, OTP verify and resend, and grant, with integration and concurrency tests.
6. Login, logout, logout-others, forgot and reset, `/v1/me`, change password, delete.
7. Google: OAuth start, callback and complete, link and unlink, JWKS refresher. *(Needs D1.)*
8. Rate limits and the Redis fallback; `GET /v1/seasons/current`.
9. Load test and report; `docs/auth/API.md`; the assumptions and TODO list.

Tenant removal (D6) goes first, as step 0, if approved.

## Assumptions so far

- Login is by email only; the current "email or username" behaviour is
  dropped (audit 23).
- Status values stay uppercase in the DB and are lowercased in API
  responses if the frontend wants them so.
- "Season 01" is `seasons.ordinal` padded to two digits by the client.
  `season_ends_at` is an RFC 3339 UTC instant; the UI formats it in
  Lagos time.
- `EMAIL_IN_USE` at signup is accepted, per the spec.
- SendByte remains the provider adapter (it already exists). The
  provider choice stays a TODO, per the spec.
- `internal/exchange/*` does not exist in this repo, so there is
  nothing to avoid touching.

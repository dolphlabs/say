# Auth: assumptions and open TODOs

## Decisions taken (with Utee, 2026-10-19)

- **RS256 in slang.** `crypto.rsa_verify_sha256` was added to slang
  (dolphlabs/slang#445), so Google ID tokens are checked against Google's
  JWKS, not trusted on TLS alone.
- **argon2id off the scheduler.** argon2id now runs on dedicated kdf
  threads while the task parks (same PR), so hashing no longer pins a
  worker or holds up garbage collection. say still bounds hashing with
  its own pool (`HASH_WORKERS`, `HASH_QUEUE`).
- **Password hashes** are standard PHC strings from
  `dolphlabs/argon v0.1.0`: argon2id m=19456 KiB, t=2, p=1. Hashes on
  older parameters are rehashed at the next login.
- **The grant across features.** `zokor check` now lets a store call
  another feature's store (dolphlabs/zokor_cli
  `feat/check-optional-tenant-auth`). The verify and Google-complete
  transactions call `ledger_store.post_signup_grant` on the same
  connection.
- **Issuance wallet.** `wallets.allow_negative` is true only for the
  seeded issuance account (`00000000-0000-4000-8000-000000000001`), so a
  grant posts as a balanced pair.
- **Tenant removed.** `tenant` and `auth` in `zokor check` are opt-in via
  `zokor.rules`. say opts into `auth require_session` only.
- **Dropped endpoints:** `GET /v1/accounts`, `GET /v1/accounts/:id`,
  `POST /v1/accounts/verify-age`, and the phone number at signup. The
  `phone_number` column stays.
- **Dev database reset**, so migration 003 restructures `accounts` in
  place (forward-only, no data conversion).

## Assumptions

- **Login is by email only.** The old "email or username" login is gone.
- **Statuses** are stored uppercase (`UNVERIFIED`, `ACTIVE`, `SUSPENDED`,
  `LOCKED`, `DELETED`). Only `ACTIVE` can sign in. Every other status
  answers `INVALID_CREDENTIALS`, except a correct password on
  `UNVERIFIED`, which answers `EMAIL_NOT_VERIFIED`.
- **Resend:** `verify_email` resends need the `signup_token`;
  `reset_password` resends take the email and always answer 202.
- **OTP misses:** the fifth wrong code still answers `OTP_INVALID` with
  `attempts_left: 0`; the next attempt answers `OTP_LOCKED`. A malformed
  code (not 6 digits) is refused without counting as an attempt.
- **No account enumeration on recovery:** an unknown email in reset
  answers `OTP_EXPIRED`, exactly as an account with no live code does.
  Signup's `EMAIL_IN_USE` is the accepted exception from the spec.
- **The outbox holds codes sealed, not in plain text.** A row carries
  the code XORed with an HMAC-SHA256 keystream (key derived from
  `OTP_SECRET`, random nonce per row) until it is delivered, then the
  payload is wiped. slang has no AES; this keeps a database dump from
  yielding live codes.
- **The session cache** in Redis holds only live sessions of active
  accounts, for at most an hour, and is deleted on revocation. A
  suspension applied directly in the database takes up to an hour to
  reach cached sessions.
- **The hashing pool defaults** to `HASH_WORKERS=2`, `HASH_QUEUE=64`. On
  N cores, keep `HASH_WORKERS` at or below N/2.
- **Grants serialise** on the issuance wallet row (one hot row per
  season). That is fine for signups; revisit before bulk season grants.
- **`username_changeable_at`** is the later of the account's own value
  and the current season's end.
- **Rate limits** count in Redis (`SET NX EX` + `INCR`) and fall back to
  a per-instance in-memory counter, with a warning logged at most once a
  minute, when Redis is unreachable. Behind a proxy, `TRUSTED_PROXIES`
  must be set or every client shares one key.
- **Delete** sets `status = DELETED` and `deleted_at`, revokes every
  session, and keeps the row and username. Nothing is anonymised yet.

## Known gaps

- **slang reactor defect under login floods** (see LOADTEST.md): an
  intermittent hang, plus one crash, after about 500 connections close
  while workers do CPU-bound work. It reproduces without the kdf offload,
  so it is pre-existing. It needs a slang fix.
- **httpc does not apply its deadline to connecting** (`net.dial`,
  `net.tls_dial`). say works around it by racing each Google and SendByte
  call against a timer, so callers get an answer on time. A lost call's
  socket lingers until the OS connect timeout (about 75 s). The real fix
  is `dial_until`, plus a `tls_dial_until` in slang.
- **One process.** Per-instance rate limiting (only when Redis is down)
  and in-memory JWKS are per process, by design.

## TODO for later prompts

- `TODO(season-rollover)`: the season job grants S 1,000 to accounts
  verified while no season was active, then on each new season (see
  `ledger/store/postgres.sl`).
- Admin roles and permissions: none exist yet. `accounts.kind` covers
  system accounts only.
- Account deletion: anonymise the username on leaderboards, purge
  personal data, decide retention.
- Email provider: SendByte is the only adapter (`EMAIL_PROVIDER=sendbyte`);
  `console` is for dev and test only.
- Google sign-in needs real `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`
  and `GOOGLE_REDIRECT_URI`, and the app's routes `/signup/google`,
  `/settings` and `/login?error=` (see API.md).
- Install slang with dolphlabs/slang#445 merged. say needs it for
  `crypto.rsa_verify_sha256`.

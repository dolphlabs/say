# AGENTS.md -- say

A zokor service, in slang. Read this before changing anything.

DO NOT ADD COMMENTS TO CODE EXCEPT WHEN NECESSARY

## Commands

- `make test`: every package's tests. `make check`: `zokor check`, tests
  and a build; run it before you finish.
- `zokor check [--json]`: the rules below, as `file:line: rule: message`
  (one JSON object per line with --json). Fix what it reports.
- `make run`: build and serve (configuration from `.env`, see `.env.example`).
- `make migrate`: apply migrations as the schema owner (`MIGRATE_DATABASE_URL`);
  the service itself runs as a `say_app` member that cannot rewrite the journal.
- `bin/say admin ...`: operator commands (roles, issuance policies).
- `zokor add feature <name>`: a new feature slice, wired in. Use it rather
  than writing the files by hand.
- `zokor add route <feature> <METHOD> <path> <handler>`: a route under the
  feature's prefix, a handler answering 501 until written, and its test.
- `slangc doc zokor <name>`: zokor's API, one item at a time.

## Layout

```
src/main.sl            startup only: config, state, mount, serve
src/platform/config/   every setting, read once (settings.sl)
src/platform/app/      App: the state handlers get as c.state
src/platform/auth/     who the caller is (require_session, the session cookie)
src/<feature>/
  domain/    types and rules; pure: no I/O, no zokor
  service/   use cases, and ports.sl: what it needs from storage
  store/     adapters implementing those ports
  server/    routes, DTOs, error codes: HTTP in and out
migrations/  NNN_description.sql, applied in order by `zokor migrate`
```

The specs' proposed paths (`internal/exchange/book/`, `match/`, `ledger/`,
`apps/say-api/` ...) are not the layout. Every part of the exchange is a
feature under `src/<feature>/` with the four layers above; pure engine
logic (book, matching, ledger rules) lives in that feature's `domain/`.

## Rules

- Imports go one way: `server -> service -> domain`; `store` implements
  `service`'s ports; `platform/app` wires stores to services. A feature
  reaches another only through that feature's `service`. Only `store/` and
  `platform/db` import pg; `domain` and `service` do no I/O.
- say is single-tenant: no tenant arguments anywhere.
- Every `server.sl` calls `auth.require_session` for its signed-in routes,
  or says `// zokor:public` if public on purpose (`zokor.rules` enforces
  this).
- A `store` may call another feature's `store` to share one transaction
  (the S 1,000 grant does); otherwise features meet only through `service`.
- SQL is a literal with `$1, $2 ...`; values never join the text.
- Configuration is read once, in `platform/config`; nothing else reads the
  environment.
- Every failure goes through a registered error code (`server/errors.sl`);
  a store's own error is logged, never sent to a client.
- Every package has a `*_test.sl` beside it. Fakes live in `*_test.sl`
  files, so they never ship.
- Comments say why, not what.

## Precedence over the global AGENTS.md

This file overrides `~/AGENTS.md` wherever they differ:

- Stack: slang + zokor. The global TypeScript/NestJS and Go/Fiber sections
  do not apply; the slang/zokor docs and the rules above do (typed
  failures are registered error codes, DTOs are `zokor.dto` structs,
  layering is `server -> service -> domain` with `store` adapters).
- Comments: only when necessary, and then why, not what. This beats the
  global "comment non-obvious decisions"; put that reasoning in the reply
  or the commit message instead.
- Git section: end a reply with the global `## Git` section (commit
  messages, PR title, PR description) only when that turn changed files.
  Read-only turns (exploring, answering questions) leave it out.

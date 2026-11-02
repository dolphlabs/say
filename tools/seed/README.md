# Seed markets

`seed-markets.mjs` creates the sample markets in `markets.json` through the
admin API: it signs in as two admins, makes sure the resolution source exists
and is approved, then creates, submits and approves each market. The server's
scheduler opens them two minutes later. It needs Node 18+ and nothing else.

Two different accounts are required, because nobody may approve a market or
source they created. Give both the `super_admin` role first:

```sh
bin/say admin role grant --account <uuid> --role super_admin
```

Run it (locally, or against staging by changing `SAY_URL`):

```sh
SAY_URL=https://staging.example.com \
SEED_AUTHOR_EMAIL=... SEED_AUTHOR_PASSWORD=... \
SEED_APPROVER_EMAIL=... SEED_APPROVER_PASSWORD=... \
node tools/seed/seed-markets.mjs            # add --dry-run to only list what it would do
```

- Re-running is safe. Markets are matched by question; finished steps are
  skipped and half-done ones (draft, in review) are carried on.
- Close times are relative to now (`close_in_days`), capped two hours before
  the active season ends, so the file never goes stale.
- `SEED_FILE` points at a different market list; `SEED_WAIT_SECONDS` (default
  240) is how long it waits to see the markets open.
- Categories are matched by name and must already exist (`GET /v1/categories`).

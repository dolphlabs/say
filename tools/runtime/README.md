# Runtime acceptance harnesses

These exercise actual service processes, the restricted `say_app` member,
PostgreSQL and Redis. Each invocation creates and migrates a uniquely named
`say_accept_*` database and drops only that database during cleanup. Redis
keys use unique market/account UUIDs; the harness never flushes shared Redis.
Fixtures fund accounts through the production ledger posting adapter.

```sh
python3 -m venv /tmp/say-runtime-venv
/tmp/say-runtime-venv/bin/pip install -r tools/runtime/requirements.txt
make test-runtime RUNTIME_PYTHON=/tmp/say-runtime-venv/bin/python
make test-runtime-differential RUNTIME_PYTHON=/tmp/say-runtime-venv/bin/python
make bench-runtime RUNTIME_PYTHON=/tmp/say-runtime-venv/bin/python
```

The Python PostgreSQL/Redis libraries are harness dependencies, not service
dependencies. Test URLs default to docker-compose.test.yml and can be set
with TEST_DATABASE_URL, TEST_APP_DATABASE_URL and TEST_REDIS_URL. Every script
supports --owner/--app/--redis, --binary and --output. Build both binaries
first when running scripts directly. Keep benchmarks isolated from other
load and compilation when comparing performance.

`acceptance.py` checks all four fill modes, exact HTTP golden A–J with actual
backed inventory, independent Python transition comparisons, private reads,
concurrent S 427 spending across ten markets, suspension/resume/close,
cross-node empty-book hydration and full reconciliation. Its process tests
use TCP protocol barriers outside the application binary:

| Window | Barrier and evidence |
|---|---|
| W1 | Pause the owner's exclusive command-frontier read; observe committed ADMITTED order, then SIGKILL; successor must execute the durable pending command |
| W2 | PostgreSQL confirms economic COMMIT but its reply is held before reaching the actor; SIGKILL, then require successor epoch/recovery |
| W3 | Stop only the proxy Redis route; observe committed command plus unpublished durable outbox, then SIGKILL |
| W4 | Hold economic COMMIT before PostgreSQL, SIGSTOP owner, allow its lease to expire, forward COMMIT and observe SAY_OWNER_FENCED from PostgreSQL; SIGKILL and successor takeover |
| W5 | Redis executes ordered XADD but its reply is dropped; observe unpublished database row and appended event, SIGKILL, retry and check one event identity in the stream |
| W6 | Close the HTTP client after observing its durable admission; retry the same key and require the same order/hold |

These hooks do not ship in `bin/say`. The database guard is tested at its
actual final-check boundary; a pause after that check is not preemptible by
an SQL clock comparison. Lost COMMIT replies are treated as unknown outcomes
until PostgreSQL recovery establishes the result.

`differential.py` defaults to 100,000 committed HTTP commands over 20 markets,
using deterministic twelve-command cycles that mint, transfer both outcomes
and merge inventory. It compares every durable resolved input/transition to
the independent Python planner, runs full reconciliation and verifies each
market through the production recovery adapter. This is a runtime
differential gate, not a new random-fuzz claim.

`load.py` defaults to five seconds of 2,000 offered requests/s per profile:
80% hot market, 1,000 distributed markets, cancel storm, 50ms PostgreSQL
transition delay, and 60 seconds of Redis outage followed by delivery drain.
The client uses 64 workers and a queue of 256. It reports client-side drops
separately from HTTP attempts, admission, completed commands and rejection.
The injected PostgreSQL delay is once per economic transition, not once per
individual SQL statement. Redis outage changes only the service's proxy,
leaving the shared test Redis available for evidence collection.

Raw JSON records duration, HTTP/health percentiles, peak service RSS,
startup recovery, command/delivery drain, remaining work, owner epochs and
reconciliation. A bounded overload profile may admit far less than offered
load; report that measured limitation explicitly. Five-second profiles are
short acceptance samples, not sustained capacity certification.

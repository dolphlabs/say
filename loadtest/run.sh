#!/bin/sh
# Load test: 500 concurrent logins on the hashing pool, and whether an
# unrelated endpoint stays fast meanwhile. Needs wrk, curl, docker and the
# test stack (make test-stack). Prints a report; see README.md.
set -eu
cd "$(dirname "$0")/.."

PORT=${LOAD_PORT:-18080}
BASE="http://127.0.0.1:$PORT"
DURATION=${LOAD_DURATION:-30s}
PG="docker exec -i say-test-postgres-1 psql -q -U say -d say_test -v ON_ERROR_STOP=1"
OUT=${LOAD_OUT:-loadtest/last-run.txt}

ulimit -n 8192 2>/dev/null || ulimit -n 4096

export ZOKOR_PROFILE=dev PORT
export DATABASE_URL='postgres://say:say-test-only@127.0.0.1:55432/say_test?sslmode=disable'
export REDIS_URL='redis://127.0.0.1:56379'
export DB_POOL_SIZE=${DB_POOL_SIZE:-20}
export OTP_SECRET='load-test-otp-secret-0123456789abcdef'
export EMAIL_PROVIDER=console
export TRUSTED_PROXIES=127.0.0.1/32
export HASH_WORKERS=${HASH_WORKERS:-4} HASH_QUEUE=${HASH_QUEUE:-64}
export LOG_REQUESTS=false

${SLANGC:-slangc} src/main.sl -o bin/say-load >/dev/null 2>&1
DATABASE_URL="$DATABASE_URL" ${ZOKOR:-zokor} migrate >/dev/null
docker exec say-test-redis-1 redis-cli FLUSHDB >/dev/null

./bin/say-load >loadtest/server.log 2>&1 &
SERVER=$!
trap 'kill -9 $SERVER 2>/dev/null || true' EXIT INT TERM
for i in $(seq 1 100); do
    curl -fs "$BASE/healthz" >/dev/null 2>&1 && break
    sleep 0.1
done

# One real signup gives a real argon2id hash; 4,999 more users share it.
curl -fs -X POST "$BASE/v1/auth/username/hold" -H 'content-type: application/json' \
    -d '{"username":"load0"}' -o /tmp/say-load-hold.json || true
HOLD=$(sed -n 's/.*"hold_id":"\([0-9a-f]*\)".*/\1/p' /tmp/say-load-hold.json)
curl -fs -X POST "$BASE/v1/auth/signup" -H 'content-type: application/json' -H 'x-forwarded-for: 10.250.0.1' \
    -d "{\"username\":\"load0\",\"hold_id\":\"$HOLD\",\"email\":\"load0@load.say\",\"password\":\"load-test-password\"}" \
    >/dev/null || true
$PG <<'SQL'
update accounts set status = 'ACTIVE', email_verified_at = now() where email = 'load0@load.say';
insert into accounts (username, email, status, email_verified_at)
select 'load' || g, 'load' || g || '@load.say', 'ACTIVE', now() from generate_series(1, 4999) g
on conflict (email) do nothing;
insert into password_credentials (account_id, hash, algo, params)
select a.id, p.hash, p.algo, p.params from accounts a
cross join (select hash, algo, params from password_credentials pc join accounts x on x.id = pc.account_id
            where x.email = 'load0@load.say') p
where a.email like 'load%@load.say' on conflict (account_id) do nothing;
SQL

CORES=$(sysctl -n hw.ncpu 2>/dev/null || nproc)
{
    echo "say load test  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "machine: $(uname -sm), $CORES cores; slang workers=default ($CORES), HASH_WORKERS=$HASH_WORKERS, HASH_QUEUE=$HASH_QUEUE, DB_POOL_SIZE=$DB_POOL_SIZE"
    echo "argon2id m=19456 KiB t=2 p=1; duration $DURATION per phase"
    echo
    echo "1) baseline: probe alone"
    PROBE_LABEL=baseline wrk -t2 -c10 -d10s -s loadtest/probe.lua "$BASE/v1/seasons/current" | grep '^probe'
    echo
    echo "2) flood: 500 concurrent logins, probe alongside"
    PROBE_LABEL=during-flood wrk -t2 -c10 -d"$DURATION" -s loadtest/probe.lua "$BASE/v1/seasons/current" \
        >/tmp/say-load-probe.txt &
    PROBE=$!
    wrk -t8 -c500 -d"$DURATION" --timeout 10s -s loadtest/login.lua "$BASE" | grep -E '^(login|Requests/sec)'
    wait $PROBE
    grep '^probe' /tmp/say-load-probe.txt
    echo
    echo "3) server 10 s after the flood"
    perl -e 'select(undef, undef, undef, 10)'
    HEALTH=$(curl -s -m 3 "$BASE/healthz" || true)
    echo "healthz: ${HEALTH:-no answer}; CLOSE_WAIT sockets: $(netstat -an | grep "$PORT" | grep -c CLOSE_WAIT); cpu: $(ps -o pcpu= -p $SERVER | tr -d ' ')%"
} | tee "$OUT"

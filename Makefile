SLANGC ?= slangc
ZOKOR ?= zokor
COMPOSE ?= docker compose -f docker-compose.test.yml
TEST_DATABASE_URL ?= postgres://say:say-test-only@127.0.0.1:55432/say_test?sslmode=disable
TEST_APP_DATABASE_URL ?= postgres://say_api:say-api-test-only@127.0.0.1:55432/say_test?sslmode=disable
TEST_REDIS_URL ?= redis://127.0.0.1:56379

.PHONY: test test-stream test-integration test-stack build run check load migrate

# Every package with tests, found rather than listed, so a new one is
# never left out. Without TEST_DATABASE_URL/TEST_REDIS_URL the Postgres
# and Redis tests skip; `make test-integration` runs them.
test:
	@set -e; for d in $$(find src -name '*_test.sl' | xargs -n1 dirname | sort -u); do \
		$(SLANGC) test $$d; \
	done
	$(MAKE) test-stream

test-stream:
	npm --prefix packages/say-stream test

test-stack:
	$(COMPOSE) up -d --wait

# The same suite against a throwaway Postgres 16 and Redis 7.
test-integration: test-stack
	TEST_DATABASE_URL='$(TEST_DATABASE_URL)' TEST_APP_DATABASE_URL='$(TEST_APP_DATABASE_URL)' \
	TEST_REDIS_URL='$(TEST_REDIS_URL)' $(MAKE) test

# Migrations run as the schema owner (MIGRATE_DATABASE_URL); the service
# connects as a member of say_app (DATABASE_URL), which cannot rewrite the
# journal.
migrate:
	DATABASE_URL="$$MIGRATE_DATABASE_URL" $(ZOKOR) migrate migrations

build:
	mkdir -p bin
	$(SLANGC) src/main.sl -o bin/say

run: build
	./bin/say

# 500 concurrent logins against a running server, with a probe on an
# unrelated endpoint; see loadtest/README.md.
load:
	sh loadtest/run.sh

# The layering, SQL, config and auth rules in AGENTS.md, then tests.
check:
	$(ZOKOR) check
	$(MAKE) test build

GO ?= go
EXCHANGE_FUZZ_COMMANDS ?= 1000000
EXCHANGE_SEED ?= 874392

.PHONY: exchange-tools test-exchange test-exchange-smoke bench-exchange

exchange-tools:
	mkdir -p bin
	$(SLANGC) tools/core/main.sl -o bin/core-driver
	$(SLANGC) tools/core/parallel/main.sl -o bin/core-parallel
	$(GO) -C bench/go-ref build -o ../../bin/go-ref .

test-exchange-smoke: exchange-tools
	$(SLANGC) test src/exchange/domain
	$(SLANGC) test src/exchange/service
	python3 -m unittest discover -s tools/oracle -v
	$(GO) -C bench/go-ref test ./...
	python3 tools/oracle/differential.py --binary bin/core-driver --commands 10000

test-exchange: test-exchange-smoke
	python3 tools/oracle/exhaustive.py --binary bin/core-parallel --alphabet reduced --depth 4
	python3 tools/oracle/parallel.py --binary bin/core-parallel --commands $(EXCHANGE_FUZZ_COMMANDS) --seed $(EXCHANGE_SEED) --trace-length 10000

bench-exchange:
	python3 bench/run.py --go $(GO)

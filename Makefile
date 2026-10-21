SLANGC ?= slangc
ZOKOR ?= zokor
COMPOSE ?= docker compose -f docker-compose.test.yml
TEST_DATABASE_URL ?= postgres://say:say-test-only@127.0.0.1:55432/say_test?sslmode=disable
TEST_APP_DATABASE_URL ?= postgres://say_api:say-api-test-only@127.0.0.1:55432/say_test?sslmode=disable
TEST_REDIS_URL ?= redis://127.0.0.1:56379

.PHONY: test test-integration test-stack build run check load migrate

# Every package with tests, found rather than listed, so a new one is
# never left out. Without TEST_DATABASE_URL/TEST_REDIS_URL the Postgres
# and Redis tests skip; `make test-integration` runs them.
test:
	@set -e; for d in $$(find src -name '*_test.sl' | xargs -n1 dirname | sort -u); do \
		$(SLANGC) test $$d; \
	done

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

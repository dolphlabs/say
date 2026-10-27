-- The test stack's runtime login: the service and the integration tests
-- connect as say_api, a member of say_app (grants in migration 004);
-- migrations run as the owner, say.
CREATE ROLE say_app NOLOGIN;
CREATE ROLE say_api LOGIN PASSWORD 'say-api-test-only' IN ROLE say_app;

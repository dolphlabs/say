import "http";
import "zokor";
import "../../platform/app" as app;
import "../service" as accounts;

// The accounts feature's error codes, registered once at startup. A failure
// is answered through these and nothing else, so every client sees the
// same envelope.
fn register_errors(r: zokor.Registry) {
    zokor.register(r, "accounts.not_found", 404, "no such account");
    zokor.register(r, "accounts.unavailable", 503, "accounts are unavailable, try again");
}

// A use case's failure, as the answer to send. A store's own error is
// logged with the request id and never reaches the client.
fn failure(c: zokor.Ctx[app.App], f: accounts.Failed) -> http.Response {
    if f.why == accounts.Why.Invalid {
        let fields: [zokor.FieldError] = [];
        for p in f.problems {
            push(fields, zokor.field(p.field, p.reason));
        }
        return zokor.respond_fields(c.errors, "validation_failed", fields, c.request_id);
    }
    if f.why == accounts.Why.NotFound {
        return zokor.respond(c.errors, "accounts.not_found", c.request_id);
    }
    c.state.settings.server.logger.error("accounts", "store failed (" + c.request_id + "): " + f.detail);
    return zokor.respond(c.errors, "accounts.unavailable", c.request_id);
}

import "http";
import "zokor";
import "../../platform/app" as app;
import "../service" as accounts;

fn register_errors(r: zokor.Registry) {
    zokor.register(r, "accounts.not_found", 404, "no such account");
    zokor.register(r, "accounts.unavailable", 503, "accounts are unavailable, try again");
    zokor.register(r, "accounts.username_taken", 409, "username is already taken");
    zokor.register(r, "accounts.email_taken", 409, "email is already registered");
    zokor.register(r, "accounts.phone_taken", 409, "phone number is already registered");
    zokor.register(r, "accounts.invalid_verification_code", 400, "invalid or expired verification code");
    zokor.register(r, "accounts.invalid_credentials", 401, "invalid email or password");
    zokor.register(r, "accounts.suspended", 403, "account is suspended or locked");
}

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
    if f.why == accounts.Why.InvalidCredentials {
        return zokor.respond(c.errors, "accounts.invalid_credentials", c.request_id);
    }
    if f.why == accounts.Why.Suspended {
        return zokor.respond(c.errors, "accounts.suspended", c.request_id);
    }
    if f.why == accounts.Why.UsernameTaken {
        return zokor.respond(c.errors, "accounts.username_taken", c.request_id);
    }
    if f.why == accounts.Why.EmailTaken {
        return zokor.respond(c.errors, "accounts.email_taken", c.request_id);
    }
    if f.why == accounts.Why.PhoneTaken {
        return zokor.respond(c.errors, "accounts.phone_taken", c.request_id);
    }
    c.state.settings.server.logger.error("accounts", "store failed (" + c.request_id + "): " + f.detail);
    return zokor.respond(c.errors, "accounts.unavailable", c.request_id);
}

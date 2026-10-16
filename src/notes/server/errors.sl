import "http";
import "zokor";
import "../../platform/app" as app;
import "../service" as notes;

fn register_errors(r: zokor.Registry) {
    zokor.register(r, "notes.not_found", 404, "no such note");
    zokor.register(r, "notes.unavailable", 503, "notes are unavailable, try again");

}

fn failure(c: zokor.Ctx[app.App], f: notes.Failed) -> http.Response {
    if f.why == notes.Why.Invalid {
        let fields: [zokor.FieldError] = [];
        for p in f.problems {
            push(fields, zokor.field(p.field, p.reason));
        }
        return zokor.respond_fields(c.errors, "validation_failed", fields, c.request_id);
    }
    if f.why == notes.Why.NotFound {
        return zokor.respond(c.errors, "notes.not_found", c.request_id);
    }
    c.state.settings.server.logger.error("notes", "store failed (" + c.request_id + "): " + f.detail);
    return zokor.respond(c.errors, "notes.unavailable", c.request_id);
}

import "http";
import "zokor";
import "../../platform/app" as app;
import "../domain" as domain;
import "../service" as ledger;

fn register_errors(r: zokor.Registry) {
    zokor.register(r, "SEASON_NOT_FOUND", 404, "There is no such season.");
    zokor.register(r, "INSUFFICIENT_FUNDS", 409, "Not enough sedis for that.");
    zokor.register(r, "IDEMPOTENCY_CONFLICT", 409, "That request was already made with different details.");
    zokor.register(r, "SEASON_MISMATCH", 409, "That belongs to another season.");
    zokor.register(r, "SEASON_NOT_ACTIVE", 409, "The season is not open for that right now.");
    zokor.register(r, "HOLD_NOT_OPEN", 409, "Those funds are no longer set aside.");
    zokor.register(r, "HOLD_EXCEEDED", 409, "That is more than was set aside.");
    zokor.register(r, "ISSUANCE_UNAVAILABLE", 503, "Season allowances are paused. Try again later.");
}

// The API code for each ledger failure, for the features that post
// through the ledger. Overflow, Unbalanced, WalletNotFound and Malformed
// are programming errors: logged, and the client sees UNAVAILABLE.
pub fn code_of_fault(f: domain.Fault) -> str {
    switch f {
        case domain.Fault.InsufficientFunds { return "INSUFFICIENT_FUNDS"; }
        case domain.Fault.IdempotencyConflict { return "IDEMPOTENCY_CONFLICT"; }
        case domain.Fault.SeasonMismatch { return "SEASON_MISMATCH"; }
        case domain.Fault.SeasonNotActive { return "SEASON_NOT_ACTIVE"; }
        case domain.Fault.HoldNotOpen { return "HOLD_NOT_OPEN"; }
        case domain.Fault.HoldExceeded { return "HOLD_EXCEEDED"; }
        case domain.Fault.PolicyMissing { return "ISSUANCE_UNAVAILABLE"; }
        case domain.Fault.CapReached { return "ISSUANCE_UNAVAILABLE"; }
        default { return "UNAVAILABLE"; }
    }
}

fn failure(c: zokor.Ctx[app.App], f: ledger.Failed) -> http.Response {
    switch f.why {
        case ledger.Why.NotFound {
            return zokor.respond(c.errors, "SEASON_NOT_FOUND", c.request_id);
        }
        case ledger.Why.BadRequest {
            return zokor.respond_fields(c.errors, "BAD_REQUEST", [zokor.field("request", f.detail)], c.request_id);
        }
        default {
            c.state.settings.server.logger.error("ledger", f.detail);
            return zokor.respond(c.errors, "UNAVAILABLE", c.request_id);
        }
    }
}

import "zokor";

pub fn register_errors(r: zokor.Registry) {
    zokor.register(r, "treasury.forbidden", 403, "You do not have permission to perform this action.");
    zokor.register(r, "treasury.bad_request", 400, "Check your request parameters.");
    zokor.register(r, "treasury.not_found", 404, "Bot or market not found.");
    zokor.register(r, "treasury.budget_cap_exceeded", 409, "Allocation would exceed the approved season budget cap.");
    zokor.register(r, "treasury.unavailable", 503, "Treasury service unavailable, try again.");
}

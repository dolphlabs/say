import "../domain" as domain;

// What the accounts service needs from storage.
pub gc struct AccountStore[C] {
    context: C,
    insert: fn(C, domain.Account) -> result[bool, str],
    find: fn(C, str, str) -> result[opt[domain.Account], str],
    find_by_email: fn(C, str, str) -> result[opt[domain.Account], str],
    list: fn(C, str, int, int) -> result[[domain.Account], str]
}

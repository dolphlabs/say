import "zokor";
import "../domain" as domain;

gc struct NewAccountDto {
    email: opt[str],
    auth_provider: opt[str]
}

fn account_json(n: domain.Account) -> zokor.Json {
    let j = zokor.jobj()
        .set_str("id", n.id)
        .set_str("auth_provider", n.auth_provider)
        .set_str("status", n.status)
        .set_str("kind", n.kind);
    if let em = n.email {
        j.set_str("email", em);
    }
    if let bg = n.beneficial_owner_group {
        j.set_str("beneficial_owner_group", bg);
    }
    j.set_bool("is_verified", domain.is_verified(n));
    j.set_bool("is_age_confirmed", domain.is_age_confirmed(n));
    j.set_bool("is_eligible_for_grant", domain.is_eligible_for_grant(n));
    return j;
}

fn accounts_json(ns: [domain.Account]) -> str {
    let arr = zokor.jarr();
    for n in ns {
        arr.add(account_json(n));
    }
    return zokor.jobj().set("data", arr).render();
}

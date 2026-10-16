import "../domain" as domain;

fn make_account(id: str, email: str) -> domain.Account {
    let none_str: opt[str] = none;
    return domain.Account {
        id: id,
        email: some(email),
        password_hash: none_str,
        auth_provider: "LOCAL",
        status: "ACTIVE",
        kind: "USER",
        beneficial_owner_group: none_str,
        email_verified_at: none_str,
        verified_at: none_str,
        age_confirmed_at: none_str,
        created_at: "2026-10-16T12:00:00Z"
    };
}

fn test_memory_insert_and_find_by_id_and_email() {
    let m = new_memory();
    let _a = memory_insert(m, make_account("acc_1", "one@say.exchange"));
    let _b = memory_insert(m, make_account("acc_2", "two@say.exchange"));

    let mine = memory_find(m, "tenant_dummy", "acc_1");
    guard let got = mine else { panic("find failed"); }
    guard let n = got else { panic("acc_1 is missing"); }
    assert(n.id == "acc_1");

    let by_em = memory_find_by_email(m, "tenant_dummy", "two@say.exchange");
    guard let got_em = by_em else { panic("find_by_email failed"); }
    guard let n2 = got_em else { panic("two@say.exchange is missing"); }
    assert(n2.id == "acc_2");
}

fn test_memory_refuses_a_duplicate_and_pages_in_order() {
    let m = new_memory();
    for id in ["1", "2", "3"] {
        let _r = memory_insert(m, make_account(id, id + "@say.exchange"));
    }
    let again = memory_insert(m, make_account("1", "1@say.exchange"));
    if let _ok = again { panic("a duplicate id was inserted"); }
    let page = memory_list(m, "tenant_dummy", 1, 1);
    guard let rows = page else { panic("list failed"); }
    assert(len(rows) == 1 && rows[0].id == "2", inspect(len(rows)));
}

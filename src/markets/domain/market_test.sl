fn facts() -> Facts {
    return Facts { season_status: "ACTIVE", season_start: 1000, season_end: 100000000, source_approved: true, category_exists: true };
}

fn complete() -> Market {
    let m = draft("11111111-1111-4111-a111-111111111111", "author", 2000);
    m.question = "Will Enyimba win on Sunday?";
    m.category_id = "category";
    m.season_id = "season";
    m.resolution_source_id = "source";
    m.yes_if = "The final official result says Enyimba won.";
    m.no_if = "The final official result is not an Enyimba win.";
    m.edge_cases = "Postponed or cancelled fixtures are reviewed for void.";
    m.open_at = 3000;
    m.close_at = 10000000;
    m.resolve_by = 14000000;
    m.redemption_units = 100;
    m.min_price = 1;
    m.max_price = 99;
    m.opening_price = 50;
    return m;
}

fn test_accepts_all_supported_payouts_and_complements() {
    for v in [10, 50, 100, 200] {
        let m = complete();
        m.redemption_units = v;
        m.max_price = v - 1;
        m.opening_price = v / 2;
        assert(len(validate(m, true, facts(), 2000)) == 0);
        for p in 1..v { assert(v - p >= m.min_price && v - p <= m.max_price); }
    }
    assert(100 * 60 / 100 == 60);
    assert(100 * 60 / 200 == 30);
}

fn test_draft_partial_fields_and_unicode_count() {
    assert(len(validate(draft("id", "author", 2000), false, facts(), 2000)) == 0);
    assert(unicode_length("₦é⚽") == 3);
    let p = empty_patch();
    p.redemption_units = some(200);
    let m = patched(draft("id", "a", 2000), p);
    assert(m.min_price == 1 && m.max_price == 199 && m.opening_price == 100);
}

fn test_all_band_time_and_source_errors_have_fields() {
    let m = complete();
    m.max_price = 98;
    m.tick = 3;
    m.close_at = facts().season_end;
    m.resolve_by = m.close_at + 3599999;
    let f = facts();
    f.source_approved = false;
    let issues = validate(m, true, f, 2000);
    let codes: [str] = [];
    for p in issues { push(codes, p.code); assert(len(p.field) > 0); }
    assert(inspect(codes) == inspect(["SOURCE_NOT_APPROVED", "CLOSE_AFTER_SEASON_END", "RESOLVE_BY_INVALID", "BAND_NOT_SYMMETRIC", "TICK_INVALID", "PRICE_RANGE_INVALID"]), inspect(codes));
    m.close_at = f.season_end - 1;
    m.resolve_by = m.close_at + 3600000;
    m.tick = 1;
    m.max_price = 99;
    assert(len(validate(m, true, facts(), 2000)) == 0);
}

fn test_state_machine_and_role_matrix() {
    let author = Actor { id: "author", roles: ["creator"] };
    let curator = Actor { id: "curator", roles: ["curator"] };
    let super = Actor { id: "author", roles: ["super_admin"] };
    let m = complete();
    let r = transition(author, "submit", m, 2000);
    guard let status = r else { panic("submit refused"); }
    assert(status == "REVIEW");
    m.status = "REVIEW";
    m.submitted_by = "author";
    let self_approval = transition(super, "approve", m, 2000);
    if let _s = self_approval { panic("self approval accepted"); } else let e = err_of(self_approval) { assert(e == "SELF_APPROVAL_FORBIDDEN"); }
    assert(authorize(author, "read", m) == "");
    assert(authorize(Actor { id: "other", roles: ["creator"] }, "read", m) == "NOT_FOUND");
    let approved = transition(curator, "approve", m, 2000);
    guard let target = approved else { panic("independent approval refused"); }
    assert(target == "APPROVED");
    for state in ["DRAFT", "REVIEW", "APPROVED", "FUNDING", "OPEN", "SUSPENDED", "CLOSED", "SETTLED"] {
        m.status = state;
        for action in ["submit", "approve", "suspend", "resume", "clarify", "reject"] {
            let t = transition(curator, action, m, 2000);
            let expected = (state == "REVIEW" && (action == "approve" || action == "reject")) ||
                           (state == "OPEN" && action == "suspend") || (state == "SUSPENDED" && action == "resume");
            if let _next = t { assert(expected, state + ":" + action); } else { assert(!expected, state + ":" + action); }
        }
    }
    m.status = "SUSPENDED";
    let expired = transition(curator, "resume", m, m.close_at);
    guard let closed = expired else { panic("expired resume"); }
    assert(closed == "CLOSED");
}

fn test_hash_is_unambiguous_and_changes_with_economics() {
    let m = complete();
    let hash = terms_hash(m, "source.v1");
    assert(hash == terms_hash(m, "source.v1") && len(hash) == 64);
    let n = copy(m);
    n.redemption_units = 200;
    assert(terms_hash(n, "source.v1") != hash);
    assert(terms_hash(m, "source.v2") != hash);
    assert(slug("Will rain fall?", "id") == "will-rain-fall-id");
}

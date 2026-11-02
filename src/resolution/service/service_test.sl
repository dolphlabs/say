import "../domain" as domain;

fn test_actor_roles() {
    let resolver_actor = Actor { id: "res_1", roles: ["resolver"] };
    assert(has_role(resolver_actor, "resolver"));
    assert(!has_role(resolver_actor, "super_admin"));

    let super_admin_actor = Actor { id: "admin_1", roles: ["super_admin"] };
    assert(has_role(super_admin_actor, "super_admin"));
    assert(has_role(super_admin_actor, "resolver")); // super_admin implies resolver

    let player_actor = Actor { id: "user_1", roles: [] };
    assert(!has_role(player_actor, "resolver"));
    assert(!has_role(player_actor, "super_admin"));
}

fn test_generic_adapter() {
    let binding = MarketTermsBinding {
        question: "Will Remo Stars win?",
        yes_if: "Remo Stars wins",
        no_if: "Remo Stars does not win"
    };

    let empty_res = generic_parse("", binding);
    assert(empty_res.verdict == domain.verdict_unclear());

    let content_res = generic_parse("Some snapshot text from web page", binding);
    assert(content_res.verdict == domain.verdict_unclear());
    assert(content_res.finding != "");
}

fn test_match_report_parser() {
    let binding = MarketTermsBinding {
        question: "Will Remo Stars defeat Sporting Lagos?",
        yes_if: "Remo Stars wins",
        no_if: "Remo Stars loses"
    };

    // 1. Match not finished yet
    let ongoing_report = "Remo Stars 1 - 0 Sporting Lagos (First Half)";
    let r1 = match_report_parse(ongoing_report, binding);
    assert(r1.verdict == domain.verdict_unclear());

    // 2. Remo Stars won 2 - 1
    let win_report = "FT: Remo Stars 2 - 1 Sporting Lagos. Remo Stars wins!";
    let r2 = match_report_parse(win_report, binding);
    assert(r2.verdict == domain.verdict_says_yes());

    // 3. Remo Stars lost 0 - 1
    let loss_report = "FT: Remo Stars 0 - 1 Sporting Lagos. Remo Stars loses!";
    let r3 = match_report_parse(loss_report, binding);
    assert(r3.verdict == domain.verdict_says_no());
}

fn test_status_notes() {
    assert(domain.note_collecting() == "Collecting results");
    assert(domain.note_proposed("Yes", 21) == "Settling · proposed Yes · 21m to dispute");
    assert(domain.note_under_review() == "Result under review");
    assert(domain.note_settled_yes() == "Settled · Yes won");
    assert(domain.note_settled_no() == "Settled · No won");
    assert(domain.note_voided() == "Voided · refunds sent");
}

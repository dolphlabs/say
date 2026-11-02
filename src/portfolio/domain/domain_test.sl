fn test_supplied_summary() {
    let s = compute_summary_valuation(427, 109, 978, 1000, true);
    assert(s.total == 1514);
    assert(s.has_season_pnl);
    assert(s.season_pnl == 514);
}

fn test_last_yes() {
    let p = compute_position_valuation(100, "YES", 3, 150, 60, true, 58, true, 62, true);
    assert(p.mark.num == 60);
    assert(p.mark.den == 1);
    assert(p.mark_source == "last_trade");
    assert(p.value == 180);
    assert(p.unrealized_pnl == 30);
    assert(p.has_pnl_pct);
    assert(p.pnl_pct == 20);
}

fn test_last_no() {
    let p = compute_position_valuation(100, "NO", 3, 150, 60, true, 58, true, 62, true);
    assert(p.mark.num == 40);
    assert(p.mark.den == 1);
    assert(p.mark_source == "last_trade");
    assert(p.value == 120);
    assert(p.unrealized_pnl == -30);
    assert(p.has_pnl_pct);
    assert(p.pnl_pct == -20);
}

fn test_odd_midpoint() {
    // V=100, Yes bid 50, ask 51, no trade -> Yes mark 50, No mark 49
    let p_yes = compute_position_valuation(100, "YES", 2, 100, 0, false, 50, true, 51, true);
    assert(p_yes.mark.num == 50);
    assert(p_yes.mark.den == 1);
    assert(p_yes.mark_source == "mid");
    assert(p_yes.value == 100);
    assert(p_yes.unrealized_pnl == 0);
    assert(p_yes.pnl_pct == 0);

    let p_no = compute_position_valuation(100, "NO", 2, 100, 0, false, 50, true, 51, true);
    assert(p_no.mark.num == 49);
    assert(p_no.mark.den == 1);
    assert(p_no.mark_source == "mid");
    assert(p_no.value == 98);
    assert(p_no.unrealized_pnl == -2);
    assert(p_no.pnl_pct == -2);
}

fn test_one_sided_quotes_fallback() {
    let p = compute_position_valuation(100, "YES", 5, 200, 0, false, 40, true, 0, false);
    assert(p.mark.num == 40);
    assert(p.mark.den == 1);
    assert(p.mark_source == "avg_cost");
    assert(p.value == 200);
    assert(p.unrealized_pnl == 0);
    assert(p.pnl_pct == 0);
}

fn test_fractional_avg_cost() {
    let p = compute_position_valuation(100, "YES", 3, 101, 0, false, 0, false, 0, false);
    assert(p.mark.num == 101);
    assert(p.mark.den == 3);
    assert(p.mark_source == "avg_cost");
    assert(p.value == 101);
    assert(p.unrealized_pnl == 0);
    assert(p.pnl_pct == 0);
}

fn test_negative_percentage() {
    let p = compute_position_valuation(100, "YES", 1, 3, 2, true, 1, true, 3, true);
    assert(p.mark.num == 2);
    assert(p.mark.den == 1);
    assert(p.value == 2);
    assert(p.unrealized_pnl == -1);
    assert(p.pnl_pct == -33);
}

fn test_zero_basis() {
    let p = compute_position_valuation(100, "YES", 2, 0, 50, true, 0, false, 0, false);
    assert(p.mark.num == 50);
    assert(p.value == 100);
    assert(p.unrealized_pnl == 100);
    assert(!p.has_pnl_pct);
}

fn test_missing_grant() {
    let s = compute_summary_valuation(500, 0, 0, 0, false);
    assert(s.total == 500);
    assert(!s.has_season_pnl);
}

fn test_win_rate_threshold() {
    assert(calculate_win_rate(1, 0) == ""); // less than 5 settled calls
    assert(calculate_win_rate(4, 0) == "");
    assert(calculate_win_rate(4, 1) == "80%"); // 5 calls
    assert(calculate_win_rate(5, 5) == "50%");
}

fn test_percentile_and_to_top20() {
    assert(calculate_percentile(38, 3180) == "top 2%");
    assert(calculate_percentile(1, 100) == "top 1%");

    let top20_res = calculate_to_top20(514, 727, 38);
    guard let diff = top20_res else { panic("expected diff"); }
    assert(diff == 214);

    let already_top = calculate_to_top20(1000, 727, 15);
    if let _ = already_top { panic("expected none for already top 20"); }
}

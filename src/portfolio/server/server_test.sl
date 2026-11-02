import "zokor";
import "../domain" as domain;

fn test_parse_season_param() {
    let empty_res = parse_season_param("");
    guard let e0 = empty_res else { panic("expected ok for empty"); }
    assert(e0 == 0);

    let cur_res = parse_season_param("current");
    guard let c0 = cur_res else { panic("expected ok for current"); }
    assert(c0 == 0);

    let one_res = parse_season_param("1");
    guard let o1 = one_res else { panic("expected ok for 1"); }
    assert(o1 == 1);

    let neg_res = parse_season_param("-1");
    if let _ = neg_res { panic("expected err for -1"); }

    let bad_res = parse_season_param("abc");
    if let _ = bad_res { panic("expected err for abc"); }
}

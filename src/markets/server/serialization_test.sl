import "json";
import "zokor";
import "../domain" as domain;
import "../service" as markets;

fn test_public_card_keeps_stats_unknown_and_hides_governance_identity() {
    let m=domain.draft("market","private-author",1000);
    m.status="SUSPENDED"; m.question="Will Enyimba win?"; m.close_at=100000;
    m.redemption_units=200; m.status_note="Reviewing source availability";
    let data=markets.new_snapshot([m],[],[],[],[],2000);
    let j=card(m,data,2000);
    assert(j.get("last_price").is_null() && j.get("chance_pct").is_null());
    assert(j.get("volume_units").is_null());
    assert(!j.has_key("created_by") && !j.has_key("approved_by") && !j.has_key("liquidity_request"));
    assert(j.get("status_note").str_or("")=="Reviewing source availability");
    data.stats_by_market[m.id]=markets.Stats { market_id:m.id,last_price:some(60),yes_bid:none,yes_ask:some(61),
        no_bid:none,no_ask:some(141),volume_units:some(100),volume_24h_units:none,players:none,change_24h:none };
    let priced=card(m,data,2000);
    assert(priced.get("chance_pct").float_or(-1.0)==30.0);
    let closed=card(m,data,m.close_at);
    assert(closed.get("status").str_or("")=="CLOSED" && !closed.get("closing_soon").bool_or(true));
}

fn test_dto_preserves_patch_omission_and_explicit_null() {
    let encoded="{\"question\":\"Will Enyimba win?\",\"category_id\":null}";
    let decoded: result[Input,str]=json.decode(encoded);
    guard let input=decoded else let e=err_of(decoded) { panic(e); }
    let parsed=zokor.parse(encoded); guard let raw=parsed else { panic("json"); }
    let patched=patch_of(input,raw); guard let p=patched else { panic("patch"); }
    guard let category=p.category_id else { panic("clear omitted"); }
    assert(category=="");
    if let _id=p.season_id { panic("omitted field changed"); }
    let bad: result[Input,str]=json.decode("{\"close_at\":\"invalid\"}");
    guard let bad_input=bad else { panic("dto"); }
    let r=patch_of(bad_input,zokor.jobj());
    if let _p=r { panic("invalid time accepted"); } else let field=err_of(r) { assert(field=="close_at"); }
}

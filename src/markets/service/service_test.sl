import "../domain" as domain;

fn test_invalid_identifiers_and_versions_never_reach_storage() {
    let f=Fake { commands:[],rows:[],failure:"" };
    let s=fake_service(f);
    let a=mutate(s,"invalid","create","",0,domain.empty_patch(),"");
    if let _m=a { panic("invalid actor accepted"); }
    let b=mutate(s,fake_id(),"edit",fake_id(),0,domain.empty_patch(),"");
    if let _m=b { panic("invalid version accepted"); }
    assert(len(f.commands)==0);
    let r=mutate(s,fake_id(),"create","",0,domain.empty_patch(),"");
    guard let m=r else { panic("create"); }
    assert(m.id==fake_id() && f.commands[0].now==100000);
}

fn test_generations_keep_old_pages_and_hide_drafts() {
    let a=domain.draft(fake_id(),"a",10); a.status="OPEN"; a.close_at=200;
    let b=domain.draft("22222222-2222-4222-a222-222222222222","b",20);
    let f=Fake { commands:[],rows:[a,b],failure:"" };
    let s=fake_service(f);
    let first=refresh(s); guard let one=first else { panic("refresh1"); }
    let old=generation(s,one); guard let old_data=old else { panic("old"); }
    assert(len(browse(old_data,"","new","all",""))==1);
    if let _private=public_market(old_data,b.id) { panic("draft leaked"); }
    f.rows=[];
    let second=refresh(s); guard let two=second else { panic("refresh2"); }
    assert(two==one+1);
    let previous=generation(s,one); guard let still=previous else { panic("cursor generation lost"); }
    assert(len(still.ordered_new)==1);
    let current=snapshot(s); guard let latest=current else { panic("latest"); }
    assert(len(latest.ordered_new)==0);
    f.failure="db down";
    let failed=refresh(s); if let _g=failed { panic("refresh failure lost"); }
    let preserved=snapshot(s); guard let retained=preserved else { panic("snapshot lost"); }
    assert(retained.generation==two);
}

fn test_sorting_and_category_search_are_deterministic() {
    let a=domain.draft("a","author",100); a.status="OPEN"; a.close_at=400; a.question="Rain in Lagos?"; a.category_id="weather";
    let b=domain.draft("b","author",200); b.status="SUSPENDED"; b.close_at=300; b.question="Will Enyimba win?"; b.category_id="football";
    let c=domain.draft("c","author",150); c.status="SETTLED"; c.close_at=200;
    let s=new_snapshot([a,b,c],[],[],[],[],100);
    index_snapshot(s);
    assert(s.ordered_new[0].id=="b");
    assert(s.ordered_ending[0].id=="c");
    assert(s.ordered_trending[0].id=="b");
    assert(len(browse(s,"football","new","open","ENYIMBA"))==1);
    assert(len(browse(s,"weather","new","resolving",""))==0);
}

gc struct ViewFake {
    views: [BookView],
    calls: int
}

fn load_ready_views(fake: ViewFake,_after: str,_limit: int) -> result[[BookView],str] {
    fake.calls+=1;
    return ok(fake.views);
}

fn view_fake_store(fake: ViewFake) -> BookViewStore[ViewFake] {
    return BookViewStore[ViewFake] { context:fake,ready_views:load_ready_views };
}

fn sample_view() -> BookView {
    return BookView {
        market_id:"00000000-0000-4000-a000-000000000001",owner_epoch:2,
        committed_seq:10,book_seq:10,last_price:some(50),pending_count:0,
        as_of:1000,lease_until:2000,health:"READY",mode:"OPEN",bids:[],asks:[]
    };
}

fn test_view_publication_never_regresses_epoch_sequence_or_freshness() {
    let old=sample_view();
    let next=sample_view();
    next.committed_seq=9; next.as_of=1500;
    assert(!newer_view(old,next));
    next.committed_seq=10; next.owner_epoch=1;
    assert(!newer_view(old,next));
    next.owner_epoch=2; next.as_of=999;
    assert(!newer_view(old,next));
    next.as_of=1001;
    assert(newer_view(old,next));
    next.owner_epoch=3; next.as_of=500;
    assert(newer_view(old,next));
}

fn test_ready_views_accepts_current_ordered_views() {
    let fake=ViewFake { views:[sample_view()],calls:0 };
    let loaded=ready_views(view_fake_store(fake),"",100);
    guard let views=loaded else let e=err_of(loaded) { panic(e); }
    assert(len(views)==1 && views[0].owner_epoch==2);
    assert(fake.calls==1);
}

fn test_ready_views_rejects_stale_or_invalid_store_data() {
    let view=sample_view();
    view.lease_until=view.as_of;
    let fake=ViewFake { views:[view],calls:0 };
    let loaded=ready_views(view_fake_store(fake),"",100);
    if let _views=loaded { panic("expired view accepted"); }
    else let e=err_of(loaded) { assert(e=="INVALID_VIEW_STATE"); }
}

fn test_ready_views_rejects_invalid_paging_before_store_access() {
    let fake=ViewFake { views:[],calls:0 };
    let loaded=ready_views(view_fake_store(fake),"",501);
    if let _views=loaded { panic("oversized view page accepted"); }
    else let e=err_of(loaded) { assert(e=="INVALID_VIEW_REQUEST"); }
    assert(fake.calls==0);
}

import "../domain" as core;

pub fn newer_view(old: BookView,next: BookView) -> bool {
    if old.market_id!=next.market_id { return false; }
    if next.owner_epoch!=old.owner_epoch { return next.owner_epoch>old.owner_epoch; }
    if next.committed_seq!=old.committed_seq { return next.committed_seq>old.committed_seq; }
    return next.as_of>=old.as_of;
}

pub fn ready_views[C](store: BookViewStore[C], after_market_id: str, limit: int) -> result[[BookView], str] {
    let scratch=core.byte_writer(36);
    if (after_market_id!="" && !core.canonical_uuid(after_market_id,scratch.data)) ||
       limit<1 || limit>500 {
        return err("INVALID_VIEW_REQUEST");
    }
    let load=store.ready_views;
    let loaded=load(store.context,after_market_id,limit);
    guard let views=loaded else let e=err_of(loaded) { return err(e); }
    let previous=after_market_id;
    for view in views {
        if !core.canonical_uuid(view.market_id,scratch.data) ||
           (previous!="" && view.market_id<=previous) ||
           view.owner_epoch<1 || view.committed_seq<view.book_seq || view.book_seq<0 ||
           view.pending_count<0 || view.as_of<1 || view.lease_until<=view.as_of ||
           view.health!="READY" || (view.mode!="OPEN" && view.mode!="SUSPENDED" && view.mode!="CLOSED") {
            return err("INVALID_VIEW_STATE");
        }
        previous=view.market_id;
    }
    return ok(views);
}

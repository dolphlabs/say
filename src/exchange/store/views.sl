import "json";
import "pg";
import "zokor";
import "../service" as service;

gc struct ReadyViewRow {
    market_id: str,
    payload: str,
    owner_epoch: int,
    committed_seq: int,
    book_seq: int,
    as_of: int,
    lease_until: int
}

fn st_ready_views(postgres: Postgres, after_market_id: str, limit: int) -> result[[service.BookView],str] {
    let rows:result[[ReadyViewRow],str]=zokor.query_all(postgres.pool,
        "select v.market_id::text as market_id,v.payload::text as payload,v.owner_epoch,"+
        "v.committed_seq,v.book_seq,floor(extract(epoch from clock_timestamp())*1000)::bigint as as_of,"+
        "floor(extract(epoch from o.lease_until)*1000)::bigint as lease_until "+
        "from market_book_views v join market_owners o on o.market_id=v.market_id and o.epoch=v.owner_epoch "+
        "join runtime_nodes n on n.id=o.node_id and n.live_until>clock_timestamp() and not n.draining "+
        "join markets m on m.id=v.market_id and m.runtime_status='READY' "+
        "where o.lease_until>clock_timestamp() and v.committed_seq=m.committed_seq and v.book_seq=m.book_seq "+
        "and ($1='' or v.market_id>nullif($1,'')::uuid) order by v.market_id limit $2",
        [pg.arg_text(after_market_id),pg.arg_int(limit)],deadline(postgres));
    guard let found=rows else let e=err_of(rows) { return err(e); }
    let views:[service.BookView]=[];
    for row in found {
        let decoded:result[service.BookView,str]=json.decode(row.payload);
        guard let view=decoded else let e=err_of(decoded) { return err("book view decode failed: "+e); }
        if view.market_id!=row.market_id || view.owner_epoch!=row.owner_epoch ||
           view.committed_seq!=row.committed_seq || view.book_seq!=row.book_seq {
            return err("persisted book view identity mismatch");
        }
        view.as_of=row.as_of;
        view.lease_until=row.lease_until;
        view.health="READY";
        push(views,view);
    }
    return ok(views);
}

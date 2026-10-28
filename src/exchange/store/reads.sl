import "pg";
import "zokor";
import "../service" as service;

gc struct OrderRow {
    order_id: str,
    market_id: str,
    status: str,
    outcome: str,
    side: str,
    price: int,
    qty: int,
    remaining: int,
    filled: int,
    cancelled: int,
    accepted_seq: int,
    fee_paid: bool,
    principal: int,
    request_type: str,
    created_at: str
}

gc struct TradeRow {
    execution_seq: int,
    fill_index: int,
    mode: str,
    qty: int,
    yes_price: int,
    created_at: str
}

gc struct CandleRow {
    bucket_at: str,
    open: int,
    high: int,
    low: int,
    close: int,
    volume: int
}

fn st_read_order(postgres: Postgres, account_id: str, order_id: str) -> result[opt[service.ReadOrder],str] {
    let rows:result[[OrderRow],str]=zokor.query_all(postgres.pool,
        "select o.id::text as order_id,o.market_id::text as market_id,o.status,o.outcome,o.side,o.limit_price as price,"+
        "original_qty as qty,remaining_qty as remaining,filled_qty as filled,cancelled_qty as cancelled,"+
        "coalesce(accepted_seq,0) as accepted_seq,fee_posted as fee_paid,created_at::text as created_at,"+
        "coalesce(original_intent->>'request_type','limit') as request_type,"+
        "coalesce((select sum(f.qty*(case when o.outcome='YES' then f.yes_equivalent_price else m.redemption_units-f.yes_equivalent_price end)) "+
        "from fills f join markets m on m.id=f.market_id where f.maker_order_id=o.id or f.taker_order_id=o.id),0)::bigint as principal "+
        "from orders o where o.id=$1::uuid and o.account_id=$2::uuid",
        [pg.arg_text(order_id),pg.arg_text(account_id)],deadline(postgres));
    guard let found=rows else let e=err_of(rows) { return err(e); }
    if len(found)==0 {
        let empty:opt[service.ReadOrder]=none;
        return ok(empty);
    }
    return ok(some(to_read_order(found[0])));
}

fn st_read_orders(postgres: Postgres, account_id: str, market_id: str, status: str,
                  after_id: str, limit: int) -> result[service.ReadOrdersPage,str] {
    let fetch_limit=limit+1;
    let rows:result[[OrderRow],str]=zokor.query_all(postgres.pool,
        "select o.id::text as order_id,o.market_id::text as market_id,o.status,o.outcome,o.side,o.limit_price as price,o.original_qty as qty,o.remaining_qty as remaining,o.filled_qty as filled,o.cancelled_qty as cancelled,coalesce(o.accepted_seq,0) as accepted_seq,o.fee_posted as fee_paid,o.created_at::text as created_at,coalesce(o.original_intent->>'request_type','limit') as request_type,coalesce((select sum(f.qty*(case when o.outcome='YES' then f.yes_equivalent_price else m.redemption_units-f.yes_equivalent_price end)) from fills f join markets m on m.id=f.market_id where f.maker_order_id=o.id or f.taker_order_id=o.id),0)::bigint as principal from orders o left join orders cursor_order on cursor_order.id=nullif($4,'')::uuid and cursor_order.account_id=$1::uuid where o.account_id=$1::uuid and (nullif($2,'')::uuid is null or o.market_id=nullif($2,'')::uuid) and ($3='all' or ($3='open' and o.status in ('ADMITTED','OPEN','PARTIAL'))) and ($4='' or (cursor_order.id is not null and (o.created_at,o.id)<(cursor_order.created_at,cursor_order.id))) order by o.created_at desc,o.id desc limit $5",
        [pg.arg_text(account_id),pg.arg_text(market_id),pg.arg_text(status),pg.arg_text(after_id),
         pg.arg_int(fetch_limit)],deadline(postgres));
    guard let found=rows else let e=err_of(rows) { return err(e); }
    let has_more=len(found)>limit;
    let items:[service.ReadOrder]=[];
    let count=len(found);
    if has_more { count=limit; }
    for i in 0..count { push(items,to_read_order(found[i])); }
    return ok(service.ReadOrdersPage { items:items,has_more:has_more });
}

fn st_read_trades(postgres: Postgres, market_id: str, before_seq: int,
                  before_index: int, limit: int) -> result[service.ReadTradesPage,str] {
    let fetch_limit=limit+1;
    let rows:result[[TradeRow],str]=zokor.query_all(postgres.pool,
        "select execution_seq,fill_index,mode,qty,yes_equivalent_price as yes_price,created_at::text as created_at from fills where market_id=$1::uuid and ($2<=0 or (execution_seq,fill_index)<($2,$3)) order by execution_seq desc,fill_index desc limit $4",
        [pg.arg_text(market_id),pg.arg_int(before_seq),pg.arg_int(before_index),pg.arg_int(fetch_limit)],
        deadline(postgres));
    guard let found=rows else let e=err_of(rows) { return err(e); }
    let has_more=len(found)>limit;
    let trades:[service.ReadTrade]=[];
    let count=len(found);
    if has_more { count=limit; }
    for i in 0..count {
        let row=found[i];
        push(trades,service.ReadTrade {
            execution_seq:row.execution_seq,fill_index:row.fill_index,mode:row.mode,
            qty:row.qty,yes_price:row.yes_price,created_at:row.created_at
        });
    }
    return ok(service.ReadTradesPage { items:trades,has_more:has_more });
}

fn st_read_history(postgres: Postgres, market_id: str, range_seconds: int,
                   bucket_seconds: int) -> result[[service.ReadCandle],str] {
    let rows:result[[CandleRow],str]=zokor.query_all(postgres.pool,
        "with points as (select minute_at,open_price,high_price,low_price,close_price,volume_units,floor(extract(epoch from minute_at)/$3)::bigint as bucket from market_price_points where market_id=$1::uuid and minute_at>=clock_timestamp()-make_interval(secs=>$2::double precision)) select to_char(to_timestamp(bucket*$3) at time zone 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') as bucket_at,(array_agg(open_price order by minute_at))[1] as open,max(high_price) as high,min(low_price) as low,(array_agg(close_price order by minute_at desc))[1] as close,sum(volume_units)::bigint as volume from points group by bucket order by bucket",
        [pg.arg_text(market_id),pg.arg_int(range_seconds),pg.arg_int(bucket_seconds)],deadline(postgres));
    guard let found=rows else let e=err_of(rows) { return err(e); }
    let candles:[service.ReadCandle]=[];
    for row in found {
        push(candles,service.ReadCandle {
            bucket_at:row.bucket_at,open:row.open,high:row.high,low:row.low,
            close:row.close,volume:row.volume
        });
    }
    return ok(candles);
}

fn to_read_order(row: OrderRow) -> service.ReadOrder {
    return service.ReadOrder {
        order_id:row.order_id,market_id:row.market_id,status:row.status,outcome:row.outcome,side:row.side,
        price:row.price,qty:row.qty,remaining:row.remaining,filled:row.filled,cancelled:row.cancelled,
        accepted_seq:row.accepted_seq,fee_paid:row.fee_paid,principal:row.principal,request_type:row.request_type,created_at:row.created_at
    };
}

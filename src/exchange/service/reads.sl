pub fn read_order[C](store: ReadStore[C], account_id: str, order_id: str) -> result[opt[ReadOrder],str] {
    if !valid_uuid(account_id) || !valid_uuid(order_id) { return err("INVALID_READ_REQUEST"); }
    let read=store.order;
    return read(store.context,account_id,order_id);
}

pub fn read_orders[C](store: ReadStore[C], account_id: str, market_id: str, status: str,
                      after_id: str, limit: int) -> result[ReadOrdersPage,str] {
    if !valid_uuid(account_id) || (market_id!="" && !valid_uuid(market_id)) ||
       (status!="all" && status!="open") || limit<1 || limit>100 ||
       (after_id!="" && !valid_uuid(after_id)) {
        return err("INVALID_READ_REQUEST");
    }
    let read=store.orders;
    return read(store.context,account_id,market_id,status,after_id,limit);
}

pub fn read_trades[C](store: ReadStore[C], market_id: str, before_seq: int,
                      before_index: int, limit: int) -> result[ReadTradesPage,str] {
    if !valid_uuid(market_id) || before_seq<0 || before_index<0 || limit<1 || limit>100 {
        return err("INVALID_READ_REQUEST");
    }
    let read=store.trades;
    return read(store.context,market_id,before_seq,before_index,limit);
}

pub fn read_history[C](store: ReadStore[C], market_id: str, range_seconds: int,
                       bucket_seconds: int) -> result[[ReadCandle],str] {
    if !valid_uuid(market_id) || range_seconds<60 || range_seconds>3153600000 || bucket_seconds<60 || bucket_seconds>31536000 {
        return err("INVALID_READ_REQUEST");
    }
    let read=store.history;
    return read(store.context,market_id,range_seconds,bucket_seconds);
}

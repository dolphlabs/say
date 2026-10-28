import "json";
import "pg";
import "zokor";
import "../domain" as core;
import "../../ledger/store" as ledger_store;
import "../service" as service;

gc struct CommitArg {
    postgres: Postgres,
    transition: service.Record,
    command: core.Command,
    node_id: str,
    epoch: int
}

gc struct MarketCommitRow {
    committed_seq: int,
    rolling_hash: str,
    season_id: str,
    redemption_units: int,
    book_mode: str
}

gc struct CommandCommitRow {
    command_type: str,
    state: str,
    order_id: str
}

gc struct PositionOrderRow {
    account_id: str,
    outcome: str,
    side: str
}

gc struct PositionRow {
    qty: int
}

gc struct AccountEvent {
    account_id: str,
    market_id: str,
    seq: int,
    order_id: str
}

gc struct MarketDeltaEvent {
    mode: str,
    book_deltas: [core.LevelDelta]
}

gc struct BookViewMeta {
    as_of: int,
    lease_until: int,
    pending_count: int,
    health: str,
    mode: str,
    book_seq: int,
    last_price: opt[int]
}

gc struct BookViewLevelRow {
    side: str,
    yes_price: int,
    qty: int
}

gc struct IdRow {
    id: str
}

gc struct FillInsertRow {
    id: str,
    minute_at_ms: int
}

fn st_commit(postgres: Postgres, transition: service.Record, command: core.Command, node_id: str, epoch: int) -> result[bool, str] {
    let committed = zokor.transaction(postgres.pool,
        CommitArg { postgres: postgres, transition: transition, command: command, node_id: node_id, epoch: epoch },
        commit_tx, deadline(postgres));
    guard let confirmed = committed else let e = err_of(committed) { return err(e); }
    return ok(confirmed);
}

fn commit_tx(conn: pg.Conn, arg: CommitArg) -> result[bool, str] {
    let record = arg.transition;
    let season = pg.query(conn,
        "select id from seasons where id=$1::uuid for share",
        [pg.arg_text(record.season_id)], deadline(arg.postgres));
    guard let _season = season else let e = err_of(season) { return err(e); }
    let halt = pg.query(conn, "select id from trading_halt where id=1 for share", [], deadline(arg.postgres));
    guard let _halt = halt else let e = err_of(halt) { return err(e); }

    let locked_market: result[[MarketCommitRow], str] = zokor.conn_query_all(conn,
        "select committed_seq,rolling_hash,season_id::text as season_id,redemption_units,book_mode " +
        "from markets where id=$1::uuid for no key update",
        [pg.arg_text(record.market_id)], deadline(arg.postgres));
    guard let markets = locked_market else let e = err_of(locked_market) { return err(e); }
    if len(markets) != 1 { return err("MARKET_NOT_FOUND"); }
    let current = markets[0];
    if current.season_id != record.season_id || current.committed_seq != record.base_seq ||
       current.rolling_hash != record.prev_hash || record.seq != record.base_seq + 1 {
        return err("TRANSITION_BASE_MISMATCH");
    }

    let command_result: result[[CommandCommitRow], str] = zokor.conn_query_all(conn,
        "select command_type,state,coalesce(order_id::text,'') as order_id " +
        "from market_commands where id=$1::uuid and market_id=$2::uuid for update",
        [pg.arg_text(record.command_ref), pg.arg_text(record.market_id)], deadline(arg.postgres));
    guard let commands = command_result else let e = err_of(command_result) { return err(e); }
    if len(commands) != 1 || commands[0].state != "PENDING" ||
       (commands[0].command_type != record.command_kind &&
        !(commands[0].command_type == "Place" && record.command_kind == "RejectPlace")) {
        return err("COMMAND_NOT_PENDING");
    }
    if arg.command.kind != record.command_kind && !(record.command_kind == "Place" && arg.command.kind == "RejectPlace") {
        return err("COMMAND_INPUT_MISMATCH");
    }
    if commands[0].order_id != "" {
        let payload_order_id = arg.command.order_id;
        if commands[0].command_type == "Place" { payload_order_id = arg.command.order.id; }
        if payload_order_id != commands[0].order_id { return err("COMMAND_ORDER_MISMATCH"); }
    }

    let permit = pg.query(conn,
        "select say_runtime_lock_permit($1::uuid,$2::uuid)",
        [pg.arg_text(record.market_id), pg.arg_text(record.command_ref)], deadline(arg.postgres));
    guard let _permit = permit else let e = err_of(permit) { return err(e); }

    let journal = service.journal_of(record);
    let posted = ledger_store.post_many_encoded(conn, journal.transactions, deadline(arg.postgres));
    guard let posting_results = posted else let e = err_of(posted) {
        return err(e);
    }

    let serialized_record = json.encode(record);
    let serialized_command = json.encode(arg.command);
    let order_updates: result[[IdRow], str] = zokor.conn_query_all(conn,
        "update orders o set remaining_qty=(v.ord->>'remaining')::bigint," +
        "filled_qty=(v.ord->>'filled')::bigint,cancelled_qty=(v.ord->>'cancelled')::bigint," +
        "sedi_consumed=(v.ord->>'sedi_consumed')::bigint,sedi_released=(v.ord->>'sedi_released')::bigint," +
        "shares_consumed=(v.ord->>'shares_consumed')::bigint,shares_released=(v.ord->>'shares_released')::bigint," +
        "fee_posted=(v.ord->>'fee_paid')::boolean," +
        "status=case when $3::jsonb->>'kind'='RejectPlace' or " +
        "($3::jsonb->>'kind'='Place' and $4<>'ACCEPTED' and o.id=($3::jsonb->'order'->>'id')::uuid) " +
        "then 'REJECTED' else v.status end," +
        "accepted_seq=(v.ord->>'accepted_seq')::bigint,revision=o.revision+1,updated_at=clock_timestamp()," +
        "committed_result=to_jsonb(v) from (select value->'order' as ord,value->>'status' as status " +
        "from jsonb_array_elements($2::jsonb->'order_updates')) v " +
        "where o.id=(v.ord->>'id')::uuid and o.market_id=$1::uuid " +
        "and o.account_id=(v.ord->>'account_id')::uuid returning o.id::text as id",
        [pg.arg_text(record.market_id), pg.arg_text(serialized_record),pg.arg_text(serialized_command),
         pg.arg_text(record.decision)], deadline(arg.postgres));
    guard let updated_orders = order_updates else let e = err_of(order_updates) { return err(e); }
    if len(updated_orders) != len(record.order_updates) { return err("ORDER_UPDATE_SET_MISMATCH"); }

    for i in 0..len(record.fills) {
        let fill = record.fills[i];
        let expected_key = "fill:" + record.market_id + ":" + to_str(record.seq) + ":" + to_str(fill.fill_index);
        let journal_id = 0;
        for j in 0..len(record.postings) {
            if record.postings[j].business_key == expected_key { journal_id = posting_results[j].tx_id; }
        }
        if journal_id < 1 { return err("FILL_JOURNAL_POSTING_MISSING"); }
        let inserted: result[[FillInsertRow], str] = zokor.conn_query_all(conn,
            "insert into fills(market_id,execution_seq,fill_index,maker_order_id,taker_order_id,mode,qty," +
            "yes_equivalent_price,journal_id,maker_account_id,taker_account_id,maker_outcome,taker_outcome," +
            "maker_side,taker_side,aggressor) " +
            "select $1::uuid,$2,$3,m.id,t.id,$4,$5,$6,$7::bigint,m.account_id,t.account_id,m.outcome,t.outcome," +
            "m.side,t.side,$8 from orders m,orders t where m.id=$9::uuid and t.id=$10::uuid " +
            "returning id::text as id,floor(extract(epoch from date_trunc('minute',executed_at))*1000)::bigint as minute_at_ms",
            [
                pg.arg_text(record.market_id), pg.arg_int(record.seq), pg.arg_int(fill.fill_index),
                pg.arg_text(fill.mode), pg.arg_int(fill.qty), pg.arg_int(fill.yes_price),
                pg.arg_int(journal_id),
                pg.arg_text(record.trades[i].aggressor), pg.arg_text(fill.maker_order_id), pg.arg_text(fill.taker_order_id)
            ], deadline(arg.postgres));
        guard let rows = inserted else let e = err_of(inserted) { return err(e); }
        if len(rows) != 1 { return err("FILL_PARTIES_NOT_FOUND"); }
        guard let volume = core.mul_units(fill.yes_price, fill.qty) else { return err("MARKET_VOLUME_OVERFLOW"); }
        let bar = pg.query(conn,
            "insert into market_price_points(market_id,minute_at,open_price,high_price,low_price,close_price,volume_units," +
            "first_seq,first_index,last_seq,last_index) " +
            "values($1::uuid,to_timestamp($2::bigint::double precision/1000.0),$3,$3,$3,$3,$4,$5,$6,$5,$6) " +
            "on conflict(market_id,minute_at) do update set " +
            "high_price=greatest(market_price_points.high_price,excluded.high_price)," +
            "low_price=least(market_price_points.low_price,excluded.low_price)," +
            "close_price=excluded.close_price,volume_units=market_price_points.volume_units+excluded.volume_units," +
            "last_seq=excluded.last_seq,last_index=excluded.last_index",
            [pg.arg_text(record.market_id),pg.arg_int(rows[0].minute_at_ms),pg.arg_int(fill.yes_price),
             pg.arg_int(volume),pg.arg_int(record.seq),pg.arg_int(fill.fill_index)],deadline(arg.postgres));
        guard let _bar = bar else let e = err_of(bar) { return err(e); }
        let maker_rows: result[[PositionOrderRow], str] = zokor.conn_query_all(conn,
            "select account_id::text as account_id,outcome,side from orders where id=$1::uuid",
            [pg.arg_text(fill.maker_order_id)], deadline(arg.postgres));
        guard let makers = maker_rows else let e = err_of(maker_rows) { return err(e); }
        let taker_rows: result[[PositionOrderRow], str] = zokor.conn_query_all(conn,
            "select account_id::text as account_id,outcome,side from orders where id=$1::uuid",
            [pg.arg_text(fill.taker_order_id)], deadline(arg.postgres));
        guard let takers = taker_rows else let e = err_of(taker_rows) { return err(e); }
        if len(makers) != 1 || len(takers) != 1 { return err("FILL_PARTIES_NOT_FOUND"); }
        let maker = makers[0];
        let taker = takers[0];
        let maker_price = fill.yes_price;
        if maker.outcome == "NO" { maker_price = current.redemption_units - fill.yes_price; }
        let taker_price = fill.yes_price;
        if taker.outcome == "NO" { taker_price = current.redemption_units - fill.yes_price; }
        let maker_position = apply_position_fill(conn, arg.postgres, record, maker, maker_price, fill.qty);
        guard let _maker_position = maker_position else let e = err_of(maker_position) { return err(e); }
        let taker_position = apply_position_fill(conn, arg.postgres, record, taker, taker_price, fill.qty);
        guard let _taker_position = taker_position else let e = err_of(taker_position) { return err(e); }
        let participant = pg.query(conn,
            "insert into market_participants(market_id,account_id,first_seq,first_at) " +
            "values($1::uuid,$2::uuid,$3,clock_timestamp()),($1::uuid,$4::uuid,$3,clock_timestamp()) " +
            "on conflict(market_id,account_id) do nothing",
            [pg.arg_text(record.market_id),pg.arg_text(maker.account_id),pg.arg_int(record.seq),pg.arg_text(taker.account_id)],
            deadline(arg.postgres));
        guard let _participant = participant else let e = err_of(participant) { return err(e); }
        let stats = pg.query(conn,
            "insert into market_stats(market_id,last_price,volume_units,players,updated_at) " +
            "values($1::uuid,$2,$3,(select count(*) from market_participants where market_id=$1::uuid),clock_timestamp()) " +
            "on conflict(market_id) do update set last_price=excluded.last_price," +
            "volume_units=coalesce(market_stats.volume_units,0)+excluded.volume_units," +
            "players=excluded.players,updated_at=clock_timestamp()",
            [pg.arg_text(record.market_id),pg.arg_int(fill.yes_price),pg.arg_int(volume)],deadline(arg.postgres));
        guard let _stats = stats else let e = err_of(stats) { return err(e); }
    }

    for update in record.order_updates {
        if !update.fee_charged_now { continue; }
        let fee_position = pg.query(conn,
            "insert into positions(account_id,market_id,season_id,outcome,fees_paid) " +
            "values($1::uuid,$2::uuid,$3::uuid,$4,1) " +
            "on conflict(account_id,market_id,season_id,outcome) do update " +
            "set fees_paid=positions.fees_paid+1,revision=positions.revision+1,updated_at=clock_timestamp()",
            [
                pg.arg_text(update.order.account_id),pg.arg_text(record.market_id),pg.arg_text(record.season_id),
                pg.arg_text(update.order.outcome)
            ],deadline(arg.postgres));
        guard let _fee_position = fee_position else let e = err_of(fee_position) { return err(e); }
    }

    let quotes = pg.query(conn,
        "insert into market_stats(market_id,yes_bid,yes_ask,no_bid,no_ask,updated_at) " +
        "select m.id," +
        "(select max(case when o.outcome='YES' then o.limit_price else m.redemption_units-o.limit_price end) " +
        "from orders o where o.market_id=m.id and o.remaining_qty>0 and o.status in ('OPEN','PARTIAL') " +
        "and ((o.outcome='YES' and o.side='BUY') or (o.outcome='NO' and o.side='SELL')))," +
        "(select min(case when o.outcome='YES' then o.limit_price else m.redemption_units-o.limit_price end) " +
        "from orders o where o.market_id=m.id and o.remaining_qty>0 and o.status in ('OPEN','PARTIAL') " +
        "and ((o.outcome='YES' and o.side='SELL') or (o.outcome='NO' and o.side='BUY')))," +
        "(select m.redemption_units-min(case when o.outcome='YES' then o.limit_price else m.redemption_units-o.limit_price end) " +
        "from orders o where o.market_id=m.id and o.remaining_qty>0 and o.status in ('OPEN','PARTIAL') " +
        "and ((o.outcome='YES' and o.side='SELL') or (o.outcome='NO' and o.side='BUY')))," +
        "(select m.redemption_units-max(case when o.outcome='YES' then o.limit_price else m.redemption_units-o.limit_price end) " +
        "from orders o where o.market_id=m.id and o.remaining_qty>0 and o.status in ('OPEN','PARTIAL') " +
        "and ((o.outcome='YES' and o.side='BUY') or (o.outcome='NO' and o.side='SELL'))),clock_timestamp() " +
        "from markets m where m.id=$1::uuid " +
        "on conflict(market_id) do update set yes_bid=excluded.yes_bid,yes_ask=excluded.yes_ask," +
        "no_bid=excluded.no_bid,no_ask=excluded.no_ask,updated_at=clock_timestamp()",
        [pg.arg_text(record.market_id)],deadline(arg.postgres));
    guard let _quotes = quotes else let e = err_of(quotes) { return err(e); }

    let next_pairs = record.supply_delta.yes;
    if record.supply_delta.yes != record.supply_delta.no { return err("SUPPLY_DELTA_MISMATCH"); }
    let update_market: result[[IdRow], str] = zokor.conn_query_all(conn,
        "update markets set committed_seq=$2,rolling_hash=$3,issued_pairs=issued_pairs+$4," +
        "book_mode=$5::jsonb->>'mode'," +
        "book_seq=case when jsonb_array_length($6::jsonb->'book_deltas')>0 or book_mode is distinct from $5::jsonb->>'mode' then $2 else book_seq end " +
        "where id=$1::uuid and committed_seq=$7 and rolling_hash=$8 returning book_seq::text as id",
        [
            pg.arg_text(record.market_id), pg.arg_int(record.seq), pg.arg_text(record.state_hash),
            pg.arg_int(next_pairs), pg.arg_text(serialized_record), pg.arg_text(serialized_record),
            pg.arg_int(record.base_seq), pg.arg_text(record.prev_hash)
        ], deadline(arg.postgres));
    guard let market_updates = update_market else let e = err_of(update_market) { return err(e); }
    if len(market_updates) != 1 { return err("MARKET_SEQUENCE_ADVANCE_FAILED"); }
    guard let book_seq = to_int(market_updates[0].id) else { return err("MARKET_BOOK_SEQUENCE_INVALID"); }

    let event_ordinal = 0;
    if len(record.book_deltas) > 0 || current.book_mode != record.mode {
        let payload = json.encode(MarketDeltaEvent { mode:record.mode,book_deltas:record.book_deltas });
        let event = pg.query(conn,
            "insert into outbox_events(market_id,market_seq,book_seq,type,payload,audience,event_ordinal,owner_epoch) " +
            "values($1::uuid,$2,$3,'book.delta',$4::jsonb,'market',$5,$6)",
            [pg.arg_text(record.market_id),pg.arg_int(record.seq),pg.arg_int(book_seq),pg.arg_text(payload),
             pg.arg_int(event_ordinal),pg.arg_int(arg.epoch)],deadline(arg.postgres));
        guard let _event = event else let e = err_of(event) { return err(e); }
        event_ordinal += 1;
    }
    for i in 0..len(record.fills) {
        let payload = json.encode(record.trades[i]);
        let event = pg.query(conn,
            "insert into outbox_events(market_id,market_seq,book_seq,type,payload,audience,event_ordinal,owner_epoch) " +
            "values($1::uuid,$2,$3,'trade',$4::jsonb,'market',$5,$6)",
            [pg.arg_text(record.market_id),pg.arg_int(record.seq),pg.arg_int(book_seq),pg.arg_text(payload),
             pg.arg_int(event_ordinal),pg.arg_int(arg.epoch)],deadline(arg.postgres));
        guard let _event = event else let e = err_of(event) { return err(e); }
        event_ordinal += 1;
    }
    for update in record.order_updates {
        let account_event = AccountEvent {
            account_id:update.order.account_id,market_id:record.market_id,seq:record.seq,order_id:update.order.id
        };
        let order_event = pg.query(conn,
            "insert into outbox_events(market_id,market_seq,book_seq,type,payload,audience,account_id,event_ordinal,owner_epoch) " +
            "values($1::uuid,$2,$3,'order.updated',$4::jsonb,'account',$5::uuid,$6,$7)",
            [pg.arg_text(record.market_id),pg.arg_int(record.seq),pg.arg_int(book_seq),pg.arg_text(json.encode(update)),
             pg.arg_text(update.order.account_id),pg.arg_int(event_ordinal),pg.arg_int(arg.epoch)],deadline(arg.postgres));
        guard let _order_event = order_event else let e = err_of(order_event) { return err(e); }
        event_ordinal += 1;
        for event_type in ["balance.changed","position.changed"] {
            let refresh = pg.query(conn,
                "insert into outbox_events(market_id,market_seq,book_seq,type,payload,audience,account_id,event_ordinal,owner_epoch) " +
                "values($1::uuid,$2,$3,$4,$5::jsonb,'account',$6::uuid,$7,$8)",
                [pg.arg_text(record.market_id),pg.arg_int(record.seq),pg.arg_int(book_seq),pg.arg_text(event_type),
                 pg.arg_text(json.encode(account_event)),pg.arg_text(update.order.account_id),
                 pg.arg_int(event_ordinal),pg.arg_int(arg.epoch)],deadline(arg.postgres));
            guard let _refresh = refresh else let e = err_of(refresh) { return err(e); }
            event_ordinal += 1;
        }
    }

    let final_state = "DONE";
    if (record.command_kind == "Place" || record.command_kind == "RejectPlace") &&
       record.decision != "ACCEPTED" { final_state = "REJECTED"; }
    let completed = pg.query(conn,
        "update market_commands set seq=$2,state=$3,resolved_input=$4::jsonb,transition=$5::jsonb," +
        "previous_hash=$6,state_hash=$7,node_id=$8::uuid,owner_epoch=$9,executed_at=clock_timestamp()," +
        "completed_at=clock_timestamp() where id=$1::uuid and state='PENDING'",
        [
            pg.arg_text(record.command_ref), pg.arg_int(record.seq), pg.arg_text(final_state),
            pg.arg_text(serialized_command), pg.arg_text(serialized_record), pg.arg_text(record.prev_hash),
            pg.arg_text(record.state_hash), pg.arg_text(arg.node_id), pg.arg_int(arg.epoch)
        ], deadline(arg.postgres));
    guard let _completed = completed else let e = err_of(completed) { return err(e); }
    if commands[0].command_type == "Place" {
        let idem_state = "COMMITTED";
        if record.decision != "ACCEPTED" { idem_state = "REJECTED"; }
        let idem_update: result[[IdRow],str] = zokor.conn_query_all(conn,
            "update idempotency_records set state=$2 where order_id=$1::uuid and scope='order' and state='PENDING' " +
            "returning order_id::text as id",
            [pg.arg_text(commands[0].order_id),pg.arg_text(idem_state)],deadline(arg.postgres));
        guard let idem_rows=idem_update else let e=err_of(idem_update) { return err(e); }
        if len(idem_rows)!=1 { return err("ORDER_IDEMPOTENCY_STATE_MISMATCH"); }
    }

    let view_meta: result[[BookViewMeta], str] = zokor.conn_query_all(conn,
        "select floor(extract(epoch from clock_timestamp())*1000)::bigint as as_of," +
        "floor(extract(epoch from o.lease_until)*1000)::bigint as lease_until," +
        "(select count(*)::integer from market_commands c where c.market_id=m.id and c.state='PENDING') as pending_count," +
        "m.runtime_status as health,m.book_mode as mode,m.book_seq," +
        "(select last_price from market_stats where market_id=m.id) as last_price " +
        "from markets m join market_owners o on o.market_id=m.id and o.epoch=$2 " +
        "where m.id=$1::uuid",
        [pg.arg_text(record.market_id),pg.arg_int(arg.epoch)],deadline(arg.postgres));
    guard let view_rows = view_meta else let e = err_of(view_meta) { return err(e); }
    if len(view_rows) != 1 { return err("BOOK_VIEW_OWNER_MISSING"); }
    let level_rows: result[[BookViewLevelRow], str] = zokor.conn_query_all(conn,
        "with levels as (" +
        "select case when (o.outcome='YES' and o.side='BUY') or (o.outcome='NO' and o.side='SELL') then 'bid' else 'ask' end as side," +
        "case when o.outcome='YES' then o.limit_price else m.redemption_units-o.limit_price end as yes_price," +
        "sum(o.remaining_qty)::bigint as qty from orders o join markets m on m.id=o.market_id " +
        "where o.market_id=$1::uuid and o.remaining_qty>0 and o.status in ('OPEN','PARTIAL') " +
        "group by 1,2), ranked as (" +
        "select side,yes_price,qty,row_number() over(partition by side order by " +
        "case when side='bid' then yes_price end desc,case when side='ask' then yes_price end asc) as rn from levels) " +
        "select side,yes_price,qty from ranked where rn<=50 order by side, " +
        "case when side='bid' then yes_price end desc,case when side='ask' then yes_price end asc",
        [pg.arg_text(record.market_id)],deadline(arg.postgres));
    guard let level_rows_list = level_rows else let e = err_of(level_rows) { return err(e); }
    let bids: [service.ViewLevel] = [];
    let asks: [service.ViewLevel] = [];
    for level in level_rows_list {
        let value = service.ViewLevel { yes_price:level.yes_price,qty:level.qty };
        if level.side == "bid" { push(bids,value); } else { push(asks,value); }
    }
    let meta = view_rows[0];
    let book_view = service.BookView {
        market_id:record.market_id,owner_epoch:arg.epoch,committed_seq:record.seq,book_seq:meta.book_seq,
        last_price:meta.last_price,pending_count:meta.pending_count,as_of:meta.as_of,lease_until:meta.lease_until,
        health:meta.health,mode:meta.mode,bids:bids,asks:asks
    };
    let saved_view = pg.query(conn,
        "insert into market_book_views(market_id,owner_epoch,committed_seq,book_seq,payload,changed_at) " +
        "values($1::uuid,$2,$3,$4,$5::jsonb,clock_timestamp()) " +
        "on conflict(market_id) do update set owner_epoch=excluded.owner_epoch,committed_seq=excluded.committed_seq," +
        "book_seq=excluded.book_seq,payload=excluded.payload,changed_at=clock_timestamp()",
        [pg.arg_text(record.market_id),pg.arg_int(arg.epoch),pg.arg_int(record.seq),pg.arg_int(meta.book_seq),
         pg.arg_text(json.encode(book_view))],deadline(arg.postgres));
    guard let _saved_view = saved_view else let e = err_of(saved_view) { return err(e); }
    return ok(true);
}

fn apply_position_fill(conn: pg.Conn, postgres: Postgres, record: service.Record, order: PositionOrderRow, price: int, qty: int) -> result[bool, str] {
    if order.side == "BUY" {
        guard let principal = core.mul_units(price, qty) else { return err("POSITION_COST_OVERFLOW"); }
        let added = pg.query(conn,
            "insert into positions(account_id,market_id,season_id,outcome,qty,cost_basis) " +
            "values($1::uuid,$2::uuid,$3::uuid,$4,$5,$6) " +
            "on conflict(account_id,market_id,season_id,outcome) do update " +
            "set qty=positions.qty+excluded.qty,cost_basis=positions.cost_basis+excluded.cost_basis," +
            "revision=positions.revision+1,updated_at=clock_timestamp()",
            [
                pg.arg_text(order.account_id),pg.arg_text(record.market_id),pg.arg_text(record.season_id),
                pg.arg_text(order.outcome),pg.arg_int(qty),pg.arg_int(principal)
            ],deadline(postgres));
        guard let _added = added else let e = err_of(added) { return err(e); }
        return ok(true);
    }
    let updated: result[[PositionRow], str] = zokor.conn_query_all(conn,
        "update positions set " +
        "cost_basis=case when qty=$5 then 0 else cost_basis-floor(cost_basis::numeric*$5::numeric/qty)::bigint end," +
        "realized_pnl=realized_pnl+($6::numeric*$5::numeric)-case when qty=$5 then cost_basis " +
        "else floor(cost_basis::numeric*$5::numeric/qty)::bigint end," +
        "qty=qty-$5,revision=revision+1,updated_at=clock_timestamp() " +
        "where account_id=$1::uuid and market_id=$2::uuid and season_id=$3::uuid and outcome=$4 and qty>=$5 " +
        "returning qty",
        [
            pg.arg_text(order.account_id),pg.arg_text(record.market_id),pg.arg_text(record.season_id),
            pg.arg_text(order.outcome),pg.arg_int(qty),pg.arg_int(price)
        ],deadline(postgres));
    guard let rows = updated else let e = err_of(updated) { return err(e); }
    if len(rows) != 1 { return err("POSITION_SELL_EXCEEDS_BALANCE"); }
    return ok(true);
}

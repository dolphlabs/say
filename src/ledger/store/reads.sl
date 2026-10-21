import "encoding";
import "pg";
import "strings";
import "timez";
import "zokor";
import "../domain" as domain;
import "../service" as service;

gc struct BalanceRow {
    season_ordinal: int,
    season_status: str,
    available: int,
    held: int,
    starting_grant: opt[int]
}

// The header balance on every page: index lookups only, no aggregation.
fn st_balance(p: Postgres, account_id: str, ordinal: int) -> result[opt[service.Balance], str] {
    let r: result[opt[BalanceRow], str] = zokor.query_one(p.pool,
        "select s.ordinal as season_ordinal, s.status as season_status, coalesce(w.free_units, 0) as available, " +
        "coalesce(w.held_units, 0) as held, g.amount as starting_grant from seasons s " +
        "left join wallets w on w.season_id = s.id and w.owner_id = $1 and w.asset_key = 'SEDI' " +
        "left join issuance_grants g on g.season_id = s.id and g.account_id = $1::uuid " +
        "where s.status = 'ACTIVE' and $2 = 0", [pg.arg_text(account_id), pg.arg_int(ordinal)], deadline(p));
    if ordinal > 0 {
        r = zokor.query_one(p.pool,
            "select s.ordinal as season_ordinal, s.status as season_status, coalesce(w.free_units, 0) as available, " +
            "coalesce(w.held_units, 0) as held, g.amount as starting_grant from seasons s " +
            "left join wallets w on w.season_id = s.id and w.owner_id = $1 and w.asset_key = 'SEDI' " +
            "left join issuance_grants g on g.season_id = s.id and g.account_id = $1::uuid " +
            "where s.ordinal = $2", [pg.arg_text(account_id), pg.arg_int(ordinal)], deadline(p));
    }
    guard let found = r else let e = err_of(r) {
        return err(e);
    }
    let none_b: opt[service.Balance] = none;
    guard let row = found else {
        return ok(none_b);
    }
    return ok(some(service.Balance { season_ordinal: row.season_ordinal, season_status: row.season_status,
                                     available: row.available, held: row.held, starting_grant: row.starting_grant }));
}

gc struct PageSeasonRow {
    id: str,
    ordinal: int
}

gc struct PageTxRow {
    id: int,
    at_text: str
}

gc struct ItemRow {
    id: int,
    public_id: str,
    created_at: timez.Time,
    at_text: str,
    kind: str,
    ref_type: str,
    ref_id: str,
    meta: str,
    asset_key: str,
    bucket: str,
    delta: int,
    free_after: opt[int],
    held_after: opt[int]
}

fn decode_cursor(cursor: str) -> result[[str], str] {
    let r = encoding.base64url_decode(cursor);
    guard let b = r else {
        return err("bad cursor");
    }
    let parts = strings.split(strings.from_bytes(b, 0, len(b)), "|");
    if len(parts) != 2 || (to_int(parts[1]) ?? -1) < 0 {
        return err("bad cursor");
    }
    return ok(parts);
}

fn encode_cursor(at_text: str, id: int) -> str {
    return encoding.base64url_encode(to_bytes(at_text + "|" + to_str(id)));
}

// Newest first, keyset on (created_at, transaction id). none when the
// season does not exist; err "bad cursor" for a cursor we did not issue.
fn st_ledger_page(p: Postgres, account_id: str, ordinal: int, cursor: str, limit: int) -> result[opt[service.LedgerPage], str] {
    let none_page: opt[service.LedgerPage] = none;
    let sr: result[opt[PageSeasonRow], str] = zokor.query_one(p.pool,
        "select id::text as id, ordinal from seasons where status = 'ACTIVE' and $1 = 0", [pg.arg_int(ordinal)], deadline(p));
    if ordinal > 0 {
        sr = zokor.query_one(p.pool, "select id::text as id, ordinal from seasons where ordinal = $1",
                             [pg.arg_int(ordinal)], deadline(p));
    }
    guard let sfound = sr else let e = err_of(sr) {
        return err(e);
    }
    guard let season = sfound else {
        return ok(none_page);
    }
    let at = "infinity";
    let before_id = 9223372036854775807;
    if len(cursor) > 0 {
        let cr = decode_cursor(cursor);
        guard let parts = cr else let e = err_of(cr) {
            return err(e);
        }
        at = parts[0];
        before_id = to_int(parts[1]) ?? 0;
    }
    let wr: result[[IdRow], str] = zokor.query_all(p.pool,
        "select id::text as id from wallets where account_id = $1::uuid and season_id = $2::uuid",
        [pg.arg_text(account_id), pg.arg_text(season.id)], deadline(p));
    guard let wallets = wr else let e = err_of(wr) {
        return err(e);
    }
    let empty: [service.LedgerItem] = [];
    if len(wallets) == 0 {
        return ok(some(service.LedgerPage { season_ordinal: season.ordinal, items: empty, next_cursor: "" }));
    }
    let wallet_ids: [str] = [];
    for w in wallets {
        push(wallet_ids, w.id);
    }
    let page_size = limit + 1;
    let tr: result[[PageTxRow], str] = zokor.query_all(p.pool,
        "select e.transaction_id as id, min(e.created_at)::text as at_text from ledger_entries e " +
        "where e.wallet_id = any($1::uuid[]) and (e.created_at, e.transaction_id) < ($2::timestamptz, $3) " +
        "group by e.transaction_id order by min(e.created_at) desc, e.transaction_id desc limit $4",
        [pg.arg_text(text_array(wallet_ids)), pg.arg_text(at), pg.arg_int(before_id), pg.arg_int(page_size)], deadline(p));
    guard let txs = tr else let e = err_of(tr) {
        return err(e);
    }
    let next = "";
    let ids: [int] = [];
    for i in 0..len(txs) {
        if i == limit {
            next = encode_cursor(txs[i - 1].at_text, txs[i - 1].id);
            break;
        }
        push(ids, txs[i].id);
    }
    if len(ids) == 0 {
        return ok(some(service.LedgerPage { season_ordinal: season.ordinal, items: empty, next_cursor: "" }));
    }
    let ir: result[[ItemRow], str] = zokor.query_all(p.pool,
        "select t.id, t.public_id::text as public_id, t.created_at, t.created_at::text as at_text, t.kind, " +
        "coalesce(t.ref_type, '') as ref_type, coalesce(t.ref_id, '') as ref_id, t.metadata::text as meta, " +
        "e.asset_key, e.bucket, e.delta, e.free_after, e.held_after " +
        "from ledger_transactions t join ledger_entries e on e.transaction_id = t.id " +
        "where t.id = any($1::bigint[]) and e.wallet_id = any($2::uuid[]) order by t.created_at desc, t.id desc, e.id",
        [pg.arg_text(int_array(ids)), pg.arg_text(text_array(wallet_ids))], deadline(p));
    guard let rows = ir else let e = err_of(ir) {
        return err(e);
    }
    let items: [service.LedgerItem] = [];
    for row in rows {
        let n = len(items);
        if n == 0 || items[n - 1].id != row.public_id {
            let none_moves: [service.AssetMove] = [];
            push(items, service.LedgerItem {
                id: row.public_id, at: row.created_at, kind: row.kind, delta: 0, held_delta: 0,
                available_after: -1, held_after: -1, ref_type: row.ref_type, ref_id: row.ref_id, meta: row.meta,
                shares: none_moves
            });
        }
        let item = items[len(items) - 1];
        if row.asset_key == domain.sedi() {
            if row.bucket == "free" {
                item.delta = item.delta + row.delta;
            } else {
                item.held_delta = item.held_delta + row.delta;
            }
            item.available_after = row.free_after ?? -1;
            item.held_after = row.held_after ?? -1;
            continue;
        }
        let moved = false;
        for m in item.shares {
            if m.asset == row.asset_key {
                if row.bucket == "free" {
                    m.free_delta = m.free_delta + row.delta;
                } else {
                    m.held_delta = m.held_delta + row.delta;
                }
                moved = true;
            }
        }
        if !moved {
            let m = service.AssetMove { asset: row.asset_key, free_delta: 0, held_delta: 0 };
            if row.bucket == "free" {
                m.free_delta = row.delta;
            } else {
                m.held_delta = row.delta;
            }
            push(item.shares, m);
        }
    }
    return ok(some(service.LedgerPage { season_ordinal: season.ordinal, items: items, next_cursor: next }));
}

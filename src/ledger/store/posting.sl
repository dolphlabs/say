import "builder";
import "encoding";
import "pg";
import "strings";
import "zokor";
import "../domain" as domain;

fn store_err(e: str) -> domain.LedgerError {
    let state = pg.sqlstate(e);
    if state == "22003" {
        return domain.failure(domain.Fault.Overflow, e);
    }
    return domain.failure(domain.Fault.Store, e);
}

// Postgres array literals for unnest(): every element quoted, so no value
// can change the array's shape; "" is NULL where the column allows it.
fn quote_elem(b: builder.Str, s: str) {
    b.write("\"");
    b.write(strings.replace(strings.replace(s, "\\", "\\\\"), "\"", "\\\""));
    b.write("\"");
}

pub fn text_array(xs: [str]) -> str {
    let b = builder.new_str().write("{");
    for i in 0..len(xs) {
        if i > 0 {
            b.write(",");
        }
        quote_elem(b, xs[i]);
    }
    return b.write("}").finish();
}

pub fn nullable_array(xs: [str]) -> str {
    let b = builder.new_str().write("{");
    for i in 0..len(xs) {
        if i > 0 {
            b.write(",");
        }
        if len(xs[i]) == 0 {
            b.write("NULL");
        } else {
            quote_elem(b, xs[i]);
        }
    }
    return b.write("}").finish();
}

pub fn int_array(xs: [int]) -> str {
    let b = builder.new_str().write("{");
    for i in 0..len(xs) {
        if i > 0 {
            b.write(",");
        }
        b.write_int(xs[i]);
    }
    return b.write("}").finish();
}

fn exec(c: pg.Conn, sql: str, args: [pg.Arg], d: until) -> result[int, str] {
    let r = pg.query(c, sql, args, d);
    guard let _rows = r else let e = err_of(r) {
        return err(e);
    }
    return ok(0);
}

gc struct TxRow {
    id: int,
    public_id: str,
    payload_hash: bytes
}

gc struct IdRow {
    id: str
}

gc struct StatusRow {
    status: str
}

gc struct MarkRow {
    before: str,
    after: str
}

gc struct WalletRow {
    wallet_id: str,
    owner_id: str,
    asset_key: str,
    free_units: int,
    held_units: int
}

gc struct SystemRow {
    wallet_id: str,
    owner_id: str,
    asset_key: str
}

gc struct HoldRow {
    id: str,
    owner_kind: str,
    owner_id: str,
    asset_key: str,
    season_id: str,
    ref_type: str,
    ref_id: str,
    status: str,
    remaining: int,
    wallet_id: str
}

gc struct Pair {
    kind: str,
    owner: str,
    asset: str
}

fn has_pair(xs: [Pair], owner: str, asset: str) -> bool {
    for p in xs {
        if p.owner == owner && p.asset == asset {
            return true;
        }
    }
    return false;
}

fn existing(c: pg.Conn, key: str, d: until) -> result[opt[TxRow], str] {
    let r: result[[TxRow], str] = zokor.conn_query_all(c,
        "select id, public_id::text as public_id, payload_hash from ledger_transactions where business_key = $1",
        [pg.arg_text(key)], d);
    guard let rows = r else let e = err_of(r) {
        return err(e);
    }
    let none_row: opt[TxRow] = none;
    if len(rows) == 0 {
        return ok(none_row);
    }
    return ok(some(rows[0]));
}

fn opened_holds(c: pg.Conn, tx_id: int, d: until) -> result[[str], str] {
    let r: result[[IdRow], str] = zokor.conn_query_all(c,
        "select id::text as id from holds where opened_tx = $1 order by id", [pg.arg_int(tx_id)], d);
    guard let rows = r else let e = err_of(r) {
        return err(e);
    }
    let out: [str] = [];
    for row in rows {
        push(out, row.id);
    }
    return ok(out);
}

// The same key with the same movement is a retry: hand back the first
// posting. With a different movement it is a caller bug or a forgery.
fn replay(c: pg.Conn, tx: domain.LedgerTx, row: TxRow, hash: bytes, d: until) -> result[domain.Posted, domain.LedgerError] {
    if encoding.hex_encode(row.payload_hash) != encoding.hex_encode(hash) {
        let e = domain.failure(domain.Fault.IdempotencyConflict, "business_key " + tx.business_key + " was posted with a different payload");
        e.wallet = tx.business_key;
        return err(e);
    }
    let hr = opened_holds(c, row.id, d);
    guard let holds = hr else let e = err_of(hr) {
        return err(store_err(e));
    }
    return ok(domain.Posted { tx_id: row.id, public_id: row.public_id, replayed: true, hold_ids: holds });
}

// A database transaction calls post or post_many once: two calls would
// lock wallets in two rounds, and two such transactions could deadlock.
fn mark_posted(c: pg.Conn, d: until) -> opt[domain.LedgerError] {
    let none_args: [pg.Arg] = [];
    let r: result[[MarkRow], str] = zokor.conn_query_all(c,
        "select coalesce(current_setting('say.ledger_posted', true), '') as before, " +
        "set_config('say.ledger_posted', '1', true) as after", none_args, d);
    guard let rows = r else let e = err_of(r) {
        return some(store_err(e));
    }
    if len(rows) == 1 && rows[0].before == "1" {
        return some(domain.failure(domain.Fault.Malformed, "post called twice in one database transaction; use post_many"));
    }
    return none;
}

fn season_status(c: pg.Conn, season_id: str, lock: bool, d: until) -> result[str, domain.LedgerError] {
    let sql = "select status from seasons where id = $1::uuid";
    if lock {
        sql = "select status from seasons where id = $1::uuid for share";
    }
    let r: result[[StatusRow], str] = zokor.conn_query_all(c, sql, [pg.arg_text(season_id)], d);
    guard let rows = r else let e = err_of(r) {
        return err(store_err(e));
    }
    if len(rows) == 0 {
        return err(domain.failure(domain.Fault.SeasonMismatch, "no season " + season_id));
    }
    return ok(rows[0].status);
}

gc struct Locked {
    states: [domain.WalletState],
    systems: [SystemRow]
}

fn wallet_of(l: Locked, owner_id: str, asset: str) -> str {
    for s in l.states {
        if s.owner_id == owner_id && s.asset_key == asset {
            return s.wallet_id;
        }
    }
    for s in l.systems {
        if s.owner_id == owner_id && s.asset_key == asset {
            return s.wallet_id;
        }
    }
    return "";
}

// Rule 2 and 3: create missing user and bot wallets, then lock every one
// this call touches in the one global order. System wallets are looked up,
// never locked.
fn lock_wallets(c: pg.Conn, season_id: str, txs: [domain.LedgerTx], d: until) -> result[Locked, domain.LedgerError] {
    let people: [Pair] = [];
    let systems: [Pair] = [];
    for tx in txs {
        for e in tx.entries {
            if e.owner.kind == "system" {
                if !has_pair(systems, e.owner.id, e.asset_key) {
                    push(systems, Pair { kind: e.owner.kind, owner: e.owner.id, asset: e.asset_key });
                }
            } else if !has_pair(people, e.owner.id, e.asset_key) {
                push(people, Pair { kind: e.owner.kind, owner: e.owner.id, asset: e.asset_key });
            }
        }
    }
    let kinds: [str] = [];
    let owners: [str] = [];
    let assets: [str] = [];
    for p in people {
        push(kinds, p.kind);
        push(owners, p.owner);
        push(assets, p.asset);
    }
    let states: [domain.WalletState] = [];
    if len(people) > 0 {
        let ins = exec(c,
            "insert into wallets (season_id, owner_kind, owner_id, account_id, asset_key) " +
            "select $1::uuid, v.kind, v.owner, a.id, v.asset " +
            "from unnest($2::text[], $3::text[], $4::text[]) as v(kind, owner, asset) " +
            "join accounts a on a.id = v.owner::uuid and lower(a.kind) = v.kind " +
            "order by v.owner collate \"C\", v.asset collate \"C\" " +
            "on conflict (season_id, owner_id, asset_key) do nothing",
            [pg.arg_text(season_id), pg.arg_text(text_array(kinds)), pg.arg_text(text_array(owners)),
             pg.arg_text(text_array(assets))], d);
        guard let _i = ins else let e = err_of(ins) {
            return err(store_err(e));
        }
        let lr: result[[WalletRow], str] = zokor.conn_query_all(c,
            "select id::text as wallet_id, owner_id, asset_key, free_units, held_units from wallets " +
            "where season_id = $1::uuid and owner_kind <> 'system' " +
            "and (owner_id, asset_key) in (select * from unnest($2::text[], $3::text[])) " +
            "order by season_id, owner_id collate \"C\", asset_key collate \"C\" for update",
            [pg.arg_text(season_id), pg.arg_text(text_array(owners)), pg.arg_text(text_array(assets))], d);
        guard let rows = lr else let e = err_of(lr) {
            return err(store_err(e));
        }
        for w in rows {
            push(states, domain.WalletState { wallet_id: w.wallet_id, owner_id: w.owner_id, asset_key: w.asset_key,
                                              free: w.free_units, held: w.held_units,
                                              free_before: w.free_units, held_before: w.held_units });
        }
        for p in people {
            let found = false;
            for s in states {
                if s.owner_id == p.owner && s.asset_key == p.asset {
                    found = true;
                }
            }
            if !found {
                let e = domain.failure(domain.Fault.WalletNotFound, "no " + p.kind + " account " + p.owner);
                e.wallet = p.owner;
                e.asset = p.asset;
                return err(e);
            }
        }
    }
    let sys: [SystemRow] = [];
    if len(systems) > 0 {
        let s_owners: [str] = [];
        let s_assets: [str] = [];
        for p in systems {
            push(s_owners, p.owner);
            push(s_assets, p.asset);
        }
        let sr: result[[SystemRow], str] = zokor.conn_query_all(c,
            "select id::text as wallet_id, owner_id, asset_key from wallets " +
            "where season_id = $1::uuid and owner_kind = 'system' " +
            "and (owner_id, asset_key) in (select * from unnest($2::text[], $3::text[]))",
            [pg.arg_text(season_id), pg.arg_text(text_array(s_owners)), pg.arg_text(text_array(s_assets))], d);
        guard let rows = sr else let e = err_of(sr) {
            return err(store_err(e));
        }
        sys = rows;
        for p in systems {
            let found = false;
            for s in sys {
                if s.owner_id == p.owner && s.asset_key == p.asset {
                    found = true;
                }
            }
            if !found {
                let e = domain.failure(domain.Fault.WalletNotFound, "no system wallet " + p.owner + " " + p.asset);
                e.wallet = p.owner;
                e.asset = p.asset;
                return err(e);
            }
        }
    }
    return ok(Locked { states: states, systems: sys });
}

fn read_hold_row(c: pg.Conn, id: str, d: until) -> result[opt[HoldRow], str] {
    let r: result[[HoldRow], str] = zokor.conn_query_all(c,
        "select h.id::text as id, w.owner_kind, w.owner_id, h.asset_key, h.season_id::text as season_id, " +
        "h.ref_type, h.ref_id, h.status, h.amount_held - h.amount_consumed - h.amount_released as remaining, " +
        "h.wallet_id::text as wallet_id " +
        "from holds h join wallets w on w.id = h.wallet_id where h.id = $1::uuid",
        [pg.arg_text(id)], d);
    guard let rows = r else let e = err_of(r) {
        return err(e);
    }
    let none_row: opt[HoldRow] = none;
    if len(rows) == 0 {
        return ok(none_row);
    }
    return ok(some(rows[0]));
}

// Rule 7: hold bookkeeping, after the wallets are locked, so every change
// to a hold is serialised by its wallet's lock.
fn apply_holds(c: pg.Conn, tx: domain.LedgerTx, tx_id: int, l: Locked, d: until) -> result[[str], domain.LedgerError] {
    let opened: [str] = [];
    for h in tx.holds {
        let wallet = wallet_of(l, h.owner.id, h.asset_key);
        if h.op == "open" {
            let r: result[[IdRow], str] = zokor.conn_query_all(c,
                "insert into holds (wallet_id, season_id, asset_key, amount_held, ref_type, ref_id, status, opened_tx) " +
                "values ($1::uuid, $2::uuid, $3, $4, $5, $6, 'open', $7) returning id::text as id",
                [pg.arg_text(wallet), pg.arg_text(tx.season_id), pg.arg_text(h.asset_key), pg.arg_int(h.amount),
                 pg.arg_text(tx.ref_type), pg.arg_text(tx.ref_id), pg.arg_int(tx_id)], d);
            guard let rows = r else let e = err_of(r) {
                return err(store_err(e));
            }
            push(opened, rows[0].id);
            continue;
        }
        let sql = "update holds set amount_consumed = amount_consumed + $2, " +
                  "status = case when amount_consumed + amount_released + $2 = amount_held then 'closed' else 'open' end, " +
                  "closed_at = case when amount_consumed + amount_released + $2 = amount_held then now() end " +
                  "where id = $1::uuid and status = 'open' and wallet_id = $3::uuid and season_id = $4::uuid " +
                  "and amount_consumed + amount_released + $2 <= amount_held returning id::text as id";
        if h.op == "release" {
            sql = "update holds set amount_released = amount_released + $2, " +
                  "status = case when amount_consumed + amount_released + $2 = amount_held then 'closed' else 'open' end, " +
                  "closed_at = case when amount_consumed + amount_released + $2 = amount_held then now() end " +
                  "where id = $1::uuid and status = 'open' and wallet_id = $3::uuid and season_id = $4::uuid " +
                  "and amount_consumed + amount_released + $2 <= amount_held returning id::text as id";
        }
        let ur: result[[IdRow], str] = zokor.conn_query_all(c, sql,
            [pg.arg_text(h.hold_id), pg.arg_int(h.amount), pg.arg_text(wallet), pg.arg_text(tx.season_id)], d);
        guard let updated = ur else let e = err_of(ur) {
            return err(store_err(e));
        }
        if len(updated) == 1 {
            continue;
        }
        let hr = read_hold_row(c, h.hold_id, d);
        guard let found = hr else let e = err_of(hr) {
            return err(store_err(e));
        }
        guard let hold = found else {
            return err(domain.failure(domain.Fault.HoldNotOpen, "no hold " + h.hold_id));
        }
        if hold.status != "open" {
            return err(domain.failure(domain.Fault.HoldNotOpen, "hold " + h.hold_id + " is closed"));
        }
        if hold.season_id != tx.season_id {
            return err(domain.failure(domain.Fault.SeasonMismatch, "hold " + h.hold_id + " is in another season"));
        }
        if hold.wallet_id != wallet {
            return err(domain.failure(domain.Fault.Malformed, "hold " + h.hold_id + " belongs to another wallet"));
        }
        let x = domain.failure(domain.Fault.HoldExceeded, "hold " + h.hold_id + " has " + to_str(hold.remaining) + " left");
        x.needed = h.amount;
        x.available = hold.remaining;
        return err(x);
    }
    return ok(opened);
}

fn hold_for(tx: domain.LedgerTx, e: domain.Entry, opened: [str]) -> str {
    if e.hold != domain.new_hold() {
        return e.hold;
    }
    let i = 0;
    for h in tx.holds {
        if h.op == "open" {
            if h.owner.id == e.owner.id && h.asset_key == e.asset_key {
                return opened[i];
            }
            i = i + 1;
        }
    }
    return "";
}

fn state_of(l: Locked, owner_id: str, asset: str) -> opt[domain.WalletState] {
    for s in l.states {
        if s.owner_id == owner_id && s.asset_key == asset {
            return some(s);
        }
    }
    return none;
}

gc struct InsertedRow {
    id: int,
    public_id: str,
    business_key: str
}

// Rules 4-6 for every transaction in the call, its wallets already locked:
// one statement inserts all the transactions, one all their entries, one
// updates every wallet that moved, however many postings there are.
fn post_batch(c: pg.Conn, txs: [domain.LedgerTx], hashes: [bytes], l: Locked, d: until) -> result[[domain.Posted], domain.LedgerError] {
    let keys: [str] = [];
    let kinds: [str] = [];
    let seasons: [str] = [];
    let markets: [str] = [];
    let ref_types: [str] = [];
    let ref_ids: [str] = [];
    let hash_hex: [str] = [];
    let metas: [str] = [];
    for i in 0..len(txs) {
        push(keys, txs[i].business_key);
        push(kinds, txs[i].kind);
        push(seasons, txs[i].season_id);
        push(markets, txs[i].market_id);
        push(ref_types, txs[i].ref_type);
        push(ref_ids, txs[i].ref_id);
        push(hash_hex, encoding.hex_encode(hashes[i]));
        push(metas, txs[i].metadata);
    }
    let ir: result[[InsertedRow], str] = zokor.conn_query_all(c,
        "insert into ledger_transactions (business_key, kind, season_id, market_id, ref_type, ref_id, payload_hash, metadata) " +
        "select v.k, v.kind, v.s::uuid, nullif(v.m, '')::uuid, nullif(v.rt, ''), nullif(v.ri, ''), decode(v.h, 'hex'), v.meta::jsonb " +
        "from unnest($1::text[], $2::text[], $3::text[], $4::text[], $5::text[], $6::text[], $7::text[], $8::text[]) " +
        "with ordinality as v(k, kind, s, m, rt, ri, h, meta, ord) order by v.ord " +
        "on conflict (business_key) do nothing returning id, public_id::text as public_id, business_key",
        [pg.arg_text(text_array(keys)), pg.arg_text(text_array(kinds)), pg.arg_text(text_array(seasons)),
         pg.arg_text(text_array(markets)), pg.arg_text(text_array(ref_types)), pg.arg_text(text_array(ref_ids)),
         pg.arg_text(text_array(hash_hex)), pg.arg_text(text_array(metas))], d);
    guard let inserted = ir else let e = err_of(ir) {
        return err(store_err(e));
    }
    let by_key: map[str]InsertedRow = {};
    for row in inserted {
        by_key[row.business_key] = row;
    }

    let out: [domain.Posted] = [];
    let tx_ids: [int] = [];
    let wallets: [str] = [];
    let assets: [str] = [];
    let buckets: [str] = [];
    let deltas: [int] = [];
    let frees: [str] = [];
    let helds: [str] = [];
    let holds: [str] = [];
    for s in l.states {
        s.free_before = s.free;
        s.held_before = s.held;
    }
    let start_free: [int] = [];
    let start_held: [int] = [];
    for s in l.states {
        push(start_free, s.free);
        push(start_held, s.held);
    }
    for i in 0..len(txs) {
        let tx = txs[i];
        if !has(by_key, tx.business_key) {
            // A concurrent caller committed this key after our first look.
            let er = existing(c, tx.business_key, d);
            guard let found = er else let e = err_of(er) {
                return err(store_err(e));
            }
            guard let row = found else {
                return err(domain.failure(domain.Fault.Store, "business key vanished: " + tx.business_key));
            }
            let rr = replay(c, tx, row, hashes[i], d);
            guard let p = rr else let e = err_of(rr) {
                return err(e);
            }
            push(out, p);
            continue;
        }
        let row = by_key[tx.business_key];
        let opened: [str] = [];
        if len(tx.holds) > 0 {
            let hr = apply_holds(c, tx, row.id, l, d);
            guard let got = hr else let e = err_of(hr) {
                return err(e);
            }
            opened = got;
        }
        // Snapshot before each posting, so InsufficientFunds reports it.
        for s in l.states {
            s.free_before = s.free;
            s.held_before = s.held;
        }
        if let problem = domain.apply(l.states, tx.entries) {
            return err(problem);
        }
        for e in tx.entries {
            push(tx_ids, row.id);
            push(wallets, wallet_of(l, e.owner.id, e.asset_key));
            push(assets, e.asset_key);
            push(buckets, e.bucket);
            push(deltas, e.delta);
            push(holds, hold_for(tx, e, opened));
            if let st = state_of(l, e.owner.id, e.asset_key) {
                push(frees, to_str(st.free));
                push(helds, to_str(st.held));
            } else {
                push(frees, "");
                push(helds, "");
            }
        }
        push(out, domain.Posted { tx_id: row.id, public_id: row.public_id, replayed: false, hold_ids: opened });
    }
    if len(tx_ids) == 0 {
        return ok(out);
    }
    let er = exec(c,
        "insert into ledger_entries (transaction_id, season_id, wallet_id, asset_key, bucket, delta, free_after, held_after, hold_id) " +
        "select v.t, $1::uuid, v.w, v.a, v.b, v.d, v.f, v.h, v.hold " +
        "from unnest($2::bigint[], $3::uuid[], $4::text[], $5::text[], $6::bigint[], $7::bigint[], $8::bigint[], $9::uuid[]) " +
        "as v(t, w, a, b, d, f, h, hold)",
        [pg.arg_text(txs[0].season_id), pg.arg_text(int_array(tx_ids)), pg.arg_text(text_array(wallets)),
         pg.arg_text(text_array(assets)), pg.arg_text(text_array(buckets)), pg.arg_text(int_array(deltas)),
         pg.arg_text(nullable_array(frees)), pg.arg_text(nullable_array(helds)), pg.arg_text(nullable_array(holds))], d);
    guard let _e = er else let e = err_of(er) {
        return err(store_err(e));
    }
    let ids: [str] = [];
    let fs: [int] = [];
    let hs: [int] = [];
    for i in 0..len(l.states) {
        let s = l.states[i];
        if s.free != start_free[i] || s.held != start_held[i] {
            push(ids, s.wallet_id);
            push(fs, s.free);
            push(hs, s.held);
        }
    }
    if len(ids) > 0 {
        let ur = exec(c,
            "update wallets w set free_units = v.f, held_units = v.h " +
            "from unnest($1::uuid[], $2::bigint[], $3::bigint[]) as v(id, f, h) where w.id = v.id",
            [pg.arg_text(text_array(ids)), pg.arg_text(int_array(fs)), pg.arg_text(int_array(hs))], d);
        guard let _u = ur else let e = err_of(ur) {
            if pg.sqlstate(e) == "23514" {
                return err(domain.failure(domain.Fault.InsufficientFunds, "balance check refused the update"));
            }
            return err(store_err(e));
        }
    }
    return ok(out);
}

// Several postings in one database transaction, all their wallets locked
// once in the global order; a fill and its fees are one call. On err the
// caller must roll back: earlier postings in the call may have written.
pub fn post_many(c: pg.Conn, txs: [domain.LedgerTx], d: until) -> result[[domain.Posted], domain.LedgerError] {
    let out: [domain.Posted] = [];
    if len(txs) == 0 {
        return ok(out);
    }
    let season_id = txs[0].season_id;
    let hashes: [bytes] = [];
    for tx in txs {
        if let problem = domain.validate(tx) {
            return err(problem);
        }
        if tx.season_id != season_id {
            return err(domain.failure(domain.Fault.SeasonMismatch, "one call posts into one season"));
        }
        push(hashes, domain.payload_hash(tx));
    }
    if let twice = mark_posted(c, d) {
        return err(twice);
    }

    // Retries are answered before any lock is taken.
    let fresh: [domain.LedgerTx] = [];
    let fresh_hashes: [bytes] = [];
    let replies: [opt[domain.Posted]] = [];
    for i in 0..len(txs) {
        let er = existing(c, txs[i].business_key, d);
        guard let found = er else let e = err_of(er) {
            return err(store_err(e));
        }
        if let row = found {
            let rr = replay(c, txs[i], row, hashes[i], d);
            guard let p = rr else let e = err_of(rr) {
                return err(e);
            }
            push(replies, some(p));
        } else {
            push(fresh, txs[i]);
            push(fresh_hashes, hashes[i]);
            let none_p: opt[domain.Posted] = none;
            push(replies, none_p);
        }
    }
    if len(fresh) == 0 {
        for r in replies {
            if let p = r {
                push(out, p);
            }
        }
        return ok(out);
    }

    let lock_season = false;
    for tx in fresh {
        if domain.needs_active(tx.kind) {
            lock_season = true;
        }
    }
    let sr = season_status(c, season_id, lock_season, d);
    guard let status = sr else let e = err_of(sr) {
        return err(e);
    }
    for tx in fresh {
        if !domain.kind_allowed(tx.kind, status) {
            let e = domain.failure(domain.Fault.SeasonNotActive, tx.kind + " is not allowed while the season is " + status);
            e.detail = status;
            return err(e);
        }
    }

    let lr = lock_wallets(c, season_id, fresh, d);
    guard let locked = lr else let e = err_of(lr) {
        return err(e);
    }
    let pr = post_batch(c, fresh, fresh_hashes, locked, d);
    guard let posted = pr else let e = err_of(pr) {
        return err(e);
    }
    let j = 0;
    for r in replies {
        if let p = r {
            push(out, p);
        } else {
            push(out, posted[j]);
            j = j + 1;
        }
    }
    return ok(out);
}

// The only door to money. Runs in the caller's transaction (never
// spawned), so a posting commits or rolls back with the work that caused
// it. On err the caller must roll back.
pub fn post(c: pg.Conn, tx: domain.LedgerTx, d: until) -> result[domain.Posted, domain.LedgerError] {
    let r = post_many(c, [tx], d);
    guard let ps = r else let e = err_of(r) {
        return err(e);
    }
    return ok(ps[0]);
}

pub fn read_hold(c: pg.Conn, hold_id: str, d: until) -> result[domain.HoldInfo, domain.LedgerError] {
    let hr = read_hold_row(c, hold_id, d);
    guard let found = hr else let e = err_of(hr) {
        return err(store_err(e));
    }
    guard let h = found else {
        return err(domain.failure(domain.Fault.HoldNotOpen, "no hold " + hold_id));
    }
    return ok(domain.HoldInfo {
        id: h.id, owner: domain.Owner { kind: h.owner_kind, id: h.owner_id }, asset_key: h.asset_key,
        season_id: h.season_id, ref_type: h.ref_type, ref_id: h.ref_id, status: h.status, remaining: h.remaining
    });
}

// free -> held for an order's worst case (or shares for a sell). Returns
// the new hold's id.
pub fn hold(c: pg.Conn, owner: domain.Owner, season_id: str, asset: str, amount: int, ref_type: str, ref_id: str,
            business_key: str, d: until) -> result[str, domain.LedgerError] {
    let r = post(c, domain.hold_tx(owner, season_id, asset, amount, ref_type, ref_id, business_key, "{}"), d);
    guard let p = r else let e = err_of(r) {
        return err(e);
    }
    if len(p.hold_ids) != 1 {
        return err(domain.failure(domain.Fault.Store, "hold posting opened " + to_str(len(p.hold_ids)) + " holds"));
    }
    return ok(p.hold_ids[0]);
}

// held -> free: cancels, unused fee holds, price improvement.
pub fn release(c: pg.Conn, hold_id: str, amount: int, business_key: str, d: until) -> result[domain.Posted, domain.LedgerError] {
    let hr = read_hold(c, hold_id, d);
    guard let h = hr else let e = err_of(hr) {
        return err(e);
    }
    return post(c, domain.release_tx(h, amount, business_key, "{}"), d);
}

// Spends held funds into `counter` (counterparty, collateral, fees).
pub fn consume(c: pg.Conn, hold_id: str, amount: int, kind: str, counter: [domain.Entry], business_key: str,
               d: until) -> result[domain.Posted, domain.LedgerError] {
    let hr = read_hold(c, hold_id, d);
    guard let h = hr else let e = err_of(hr) {
        return err(e);
    }
    return post(c, domain.consume_tx(h, amount, kind, counter, business_key, "{}"), d);
}

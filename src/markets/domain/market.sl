import "strings";
import "builder";
import "crypto";
import "encoding";

pub gc struct Market {
    id: str,
    slug: str,
    question: str,
    category_id: str,
    season_id: str,
    resolution_source_id: str,
    yes_if: str,
    no_if: str,
    edge_cases: str,
    open_at: int,
    close_at: int,
    resolve_by: int,
    redemption_units: int,
    min_price: int,
    max_price: int,
    tick: int,
    max_order_qty: int,
    fee_units: int,
    min_order_notional: int,
    liquidity_request: int,
    featured_rank: int,
    opening_price: int,
    status: str,
    version: int,
    terms_version: int,
    terms_hash: str,
    created_by: str,
    submitted_by: str,
    approved_by: str,
    created_at: int,
    updated_at: int,
    opened_at: int,
    closed_at: int,
    suspended_at: int,
    suspend_reason: str,
    status_note: str,
}

pub gc struct Patch {
    question: opt[str],
    category_id: opt[str],
    season_id: opt[str],
    resolution_source_id: opt[str],
    yes_if: opt[str],
    no_if: opt[str],
    edge_cases: opt[str],
    open_at: opt[int],
    close_at: opt[int],
    resolve_by: opt[int],
    redemption_units: opt[int],
    min_price: opt[int],
    max_price: opt[int],
    tick: opt[int],
    max_order_qty: opt[int],
    fee_units: opt[int],
    min_order_notional: opt[int],
    liquidity_request: opt[int],
    featured_rank: opt[int],
    opening_price: opt[int],
}

pub gc struct Problem { code: str, field: str, message: str }

pub gc struct Actor { id: str, roles: [str] }

pub gc struct Facts { season_status: str, season_start: int, season_end: int, source_approved: bool, category_exists: bool }

pub fn empty_patch() -> Patch {
    return Patch { question: none, category_id: none, season_id: none, resolution_source_id: none, yes_if: none, no_if: none, edge_cases: none, open_at: none, close_at: none, resolve_by: none, redemption_units: none, min_price: none, max_price: none, tick: none, max_order_qty: none, fee_units: none, min_order_notional: none, liquidity_request: none, featured_rank: none, opening_price: none };
}

pub fn draft(id: str, actor: str, now: int) -> Market {
    return Market {
        id: id,
        slug: "market-" + id,
        question: "",
        category_id: "",
        season_id: "",
        resolution_source_id: "",
        yes_if: "",
        no_if: "",
        edge_cases: "",
        open_at: 0,
        close_at: 0,
        resolve_by: 0,
        redemption_units: 0,
        min_price: 0,
        max_price: 0,
        tick: 1,
        max_order_qty: 10000,
        fee_units: 1,
        min_order_notional: 2,
        liquidity_request: 0,
        featured_rank: 0,
        opening_price: 0,
        status: "DRAFT",
        version: 1,
        terms_version: 0,
        terms_hash: "",
        created_by: actor,
        submitted_by: "",
        approved_by: "",
        created_at: now,
        updated_at: now,
        opened_at: 0,
        closed_at: 0,
        suspended_at: 0,
        suspend_reason: "",
        status_note: ""
    };
}

pub fn copy(m: Market) -> Market {
    return Market { id: m.id, slug: m.slug, question: m.question, category_id: m.category_id, season_id: m.season_id, resolution_source_id: m.resolution_source_id, yes_if: m.yes_if, no_if: m.no_if, edge_cases: m.edge_cases, open_at: m.open_at, close_at: m.close_at, resolve_by: m.resolve_by, redemption_units: m.redemption_units, min_price: m.min_price, max_price: m.max_price, tick: m.tick, max_order_qty: m.max_order_qty, fee_units: m.fee_units, min_order_notional: m.min_order_notional, liquidity_request: m.liquidity_request, featured_rank: m.featured_rank, opening_price: m.opening_price, status: m.status, version: m.version, terms_version: m.terms_version, terms_hash: m.terms_hash, created_by: m.created_by, submitted_by: m.submitted_by, approved_by: m.approved_by, created_at: m.created_at, updated_at: m.updated_at, opened_at: m.opened_at, closed_at: m.closed_at, suspended_at: m.suspended_at, suspend_reason: m.suspend_reason, status_note: m.status_note };
}

pub fn patched(m: Market, p: Patch) -> Market {
    let n = copy(m);
    if let v = p.question { n.question = v; }
    if let v = p.category_id { n.category_id = v; }
    if let v = p.season_id { n.season_id = v; }
    if let v = p.resolution_source_id { n.resolution_source_id = v; }
    if let v = p.yes_if { n.yes_if = v; }
    if let v = p.no_if { n.no_if = v; }
    if let v = p.edge_cases { n.edge_cases = v; }
    if let v = p.open_at { n.open_at = v; }
    if let v = p.close_at { n.close_at = v; }
    if let v = p.resolve_by { n.resolve_by = v; }
    if let v = p.redemption_units { n.redemption_units = v; }
    if let v = p.min_price { n.min_price = v; }
    if let v = p.max_price { n.max_price = v; }
    if let v = p.tick { n.tick = v; }
    if let v = p.max_order_qty { n.max_order_qty = v; }
    if let v = p.fee_units { n.fee_units = v; }
    if let v = p.min_order_notional { n.min_order_notional = v; }
    if let v = p.liquidity_request { n.liquidity_request = v; }
    if let v = p.featured_rank { n.featured_rank = v; }
    if let v = p.opening_price { n.opening_price = v; }
    if n.redemption_units > 0 {
        if n.min_price == 0 { n.min_price = 1; }
        if n.max_price == 0 { n.max_price = n.redemption_units - 1; }
        if n.opening_price == 0 && n.tick > 0 { n.opening_price = (n.redemption_units / 2 / n.tick) * n.tick; }
    }
    return n;
}

pub fn has_role(a: Actor, role: str) -> bool {
    for r in a.roles { if r == role { return true; } }
    return false;
}

pub fn reviewer(a: Actor) -> bool {
    return has_role(a, "curator") || has_role(a, "super_admin");
}

pub fn editable(m: Market) -> bool {
    return m.status == "DRAFT" || m.status == "CHANGES_REQUESTED";
}

pub fn public_status(status: str) -> bool {
    return status == "OPEN" || status == "SUSPENDED" || status == "CLOSED" || status == "RESOLUTION_PENDING" ||
           status == "DISPUTED" || status == "RESOLVED" || status == "VOIDED" || status == "SETTLING" || status == "SETTLED";
}

pub fn authorize(a: Actor, action: str, m: Market) -> str {
    if action == "create" {
        if has_role(a, "creator") || reviewer(a) { return ""; }
        return "FORBIDDEN_ROLE";
    }
    if action == "read" {
        if reviewer(a) || (has_role(a, "creator") && a.id == m.created_by) { return ""; }
        return "NOT_FOUND";
    }
    if action == "edit" || action == "submit" {
        if a.id != m.created_by || (!has_role(a, "creator") && !reviewer(a)) { return "FORBIDDEN_ROLE"; }
        return "";
    }
    if action == "clarify" {
        if has_role(a, "super_admin") { return ""; }
        return "FORBIDDEN_ROLE";
    }
    if !reviewer(a) { return "FORBIDDEN_ROLE"; }
    if action == "approve" && a.id == m.submitted_by { return "SELF_APPROVAL_FORBIDDEN"; }
    return "";
}

pub fn transition(a: Actor, action: str, m: Market, now: int) -> result[str, str] {
    let denied = authorize(a, action, m);
    if len(denied) > 0 { return err(denied); }
    let edges = ["DRAFT:submit:REVIEW", "CHANGES_REQUESTED:submit:REVIEW", "REVIEW:approve:APPROVED",
                 "REVIEW:request-changes:CHANGES_REQUESTED", "REVIEW:reject:REJECTED",
                 "OPEN:suspend:SUSPENDED", "SUSPENDED:resume:OPEN", "OPEN:clarify:OPEN"];
    if action == "edit" {
        if editable(m) { return ok(m.status); }
        return err("LOCKED_AFTER_OPEN");
    }
    for edge in edges {
        let v = strings.split(edge, ":");
        if v[0] == m.status && v[1] == action {
            if action == "resume" && now >= m.close_at { return ok("CLOSED"); }
            return ok(v[2]);
        }
    }
    return err("INVALID_TRANSITION");
}

pub fn unicode_length(s: str) -> int {
    let count = 0;
    for b in to_bytes(s) { if ((b as int) & 192) != 128 { count += 1; } }
    return count;
}

fn issue(out: [Problem], code: str, field: str, message: str) {
    push(out, Problem { code: code, field: field, message: message });
}

fn rule_text(out: [Problem], value: str, field: str, full: bool) {
    let n = unicode_length(strings.trim(value));
    if (full || n > 0) && (n < 20 || n > 600) { issue(out, "RULES_INCOMPLETE", field, "Use 20–600 characters."); }
}

pub fn validate(m: Market, full: bool, f: Facts, now: int) -> [Problem] {
    let out: [Problem] = [];
    let n = unicode_length(strings.trim(m.question));
    if (full || n > 0) && (n < 10 || n > 140) { issue(out, "QUESTION_INVALID", "question", "Use 10–140 characters for one yes/no question."); }
    rule_text(out, m.yes_if, "rules.yes_if", full);
    rule_text(out, m.no_if, "rules.no_if", full);
    rule_text(out, m.edge_cases, "rules.edge_cases", full);
    if (full || len(m.category_id) > 0) && !f.category_exists { issue(out, "BAD_REQUEST", "category_id", "Choose an existing category."); }
    if (full || len(m.resolution_source_id) > 0) && !f.source_approved { issue(out, "SOURCE_NOT_APPROVED", "resolution_source_id", "Choose an approved resolution source."); }
    if (full || len(m.season_id) > 0) && f.season_status != "ACTIVE" && f.season_status != "SCHEDULED" { issue(out, "SEASON_NOT_OPEN", "season_id", "Choose an active or scheduled season."); }
    if full || m.close_at != 0 {
        if m.close_at <= now || (f.season_end > 0 && m.close_at >= f.season_end) {
            issue(out, "CLOSE_AFTER_SEASON_END", "close_at", "Trading must close in the future and before the season ends.");
        }
        if m.open_at > 0 && (m.open_at >= m.close_at || (f.season_start > 0 && m.open_at < f.season_start)) {
            issue(out, "BAD_REQUEST", "open_at", "Opening must be inside the season and before closing.");
        }
    }
    if full || m.resolve_by != 0 {
        if m.close_at == 0 || m.resolve_by < m.close_at + 3600000 || m.resolve_by > m.close_at + 172800000 {
            issue(out, "RESOLVE_BY_INVALID", "resolve_by", "Resolve one to forty-eight hours after closing.");
        }
    }
    if full || m.redemption_units != 0 {
        if m.redemption_units < 10 || m.redemption_units > 1000 { issue(out, "PAYOUT_INVALID", "redemption_units", "Use an integer from 10 to 1000."); }
    }
    if full || m.min_price != 0 || m.max_price != 0 {
        if m.min_price < 1 || m.max_price < m.min_price || m.max_price >= m.redemption_units { issue(out, "PRICE_RANGE_INVALID", "min_price", "Prices must be between 1 and payout minus 1."); }
        if m.min_price + m.max_price != m.redemption_units { issue(out, "BAND_NOT_SYMMETRIC", "max_price", "The band endpoints must sum to the payout."); }
    }
    if m.tick < 1 || (m.tick > 0 && (m.min_price % m.tick != 0 || (m.max_price - m.min_price) % m.tick != 0 || m.redemption_units % m.tick != 0)) {
        issue(out, "TICK_INVALID", "tick", "The tick must divide the payout and price grid.");
    }
    if m.max_order_qty < 1 || m.max_order_qty > 10000000 { issue(out, "BAD_REQUEST", "max_order_qty", "Use 1–10000000 shares."); }
    if m.fee_units != 1 || m.min_order_notional != 2 { issue(out, "BAD_REQUEST", "fee_units", "The order fee and minimum notional are fixed at 1 and 2."); }
    if m.liquidity_request < 0 || m.liquidity_request > 1000000000000 || m.featured_rank < 0 { issue(out, "BAD_REQUEST", "liquidity_request", "Use a positive bounded allocation or omit it."); }
    if m.opening_price != 0 && (m.opening_price < m.min_price || m.opening_price > m.max_price || (m.tick > 0 && m.opening_price % m.tick != 0)) {
        issue(out, "PRICE_RANGE_INVALID", "opening_price", "The opening price must be on the approved grid.");
    }
    return out;
}

pub fn slug(question: str, id: str) -> str {
    let out = "";
    let dash = false;
    let lower = strings.to_lower(question);
    let raw = to_bytes(lower);
    for i in 0..len(raw) {
        let b = raw[i];
        if (b >= 97 && b <= 122) || (b >= 48 && b <= 57) {
            if dash && len(out) > 0 { out += "-"; }
            out += strings.slice(lower, i, i + 1);
            dash = false;
        } else { dash = true; }
        if len(out) >= 80 { break; }
    }
    if len(out) == 0 { out = "market"; }
    return out + "-" + id;
}

pub fn terms_payload(m: Market, source_snapshot: str) -> str {
    let b = builder.new_str();
    for value in ["say.market.v1", m.id, m.question, m.category_id, m.season_id, m.yes_if, m.no_if, m.edge_cases,
        m.resolution_source_id, source_snapshot, to_str(m.open_at), to_str(m.close_at), to_str(m.resolve_by),
        to_str(m.redemption_units), to_str(m.min_price), to_str(m.max_price), to_str(m.tick), to_str(m.max_order_qty),
        to_str(m.fee_units), to_str(m.min_order_notional), to_str(m.liquidity_request), to_str(m.opening_price)] {
        b.write_int(len(value)).write(":").write(value);
    }
    return b.finish();
}

pub fn terms_hash(m: Market, source_snapshot: str) -> str {
    return encoding.hex_encode(crypto.sha256(to_bytes(terms_payload(m,source_snapshot))));
}

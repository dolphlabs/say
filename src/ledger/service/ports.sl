import "timez";
import "../domain" as domain;

pub gc struct TickReport {
    steps: [domain.Step],
    closed: [int],
    rollover: str,
    problems: [str]
}

pub gc struct GrantRun {
    season_id: str,
    last_account_id: str,
    granted: int,
    skipped: int,
    finished: bool,
    halted_reason: str
}

pub gc struct ChunkResult {
    granted: int,
    skipped: int,
    halt: str
}

pub gc struct Balance {
    season_ordinal: int,
    season_status: str,
    available: int,
    held: int,
    starting_grant: opt[int]
}

pub gc struct AssetMove {
    asset: str,
    free_delta: int,
    held_delta: int
}

pub gc struct LedgerItem {
    id: str,
    at: timez.Time,
    kind: str,
    delta: int,
    held_delta: int,
    available_after: int,
    held_after: int,
    ref_type: str,
    ref_id: str,
    meta: str,
    shares: [AssetMove]
}

pub gc struct LedgerPage {
    season_ordinal: int,
    items: [LedgerItem],
    next_cursor: str
}

pub gc struct ReconRun {
    id: str,
    scope: str,
    status: str,
    started_at: opt[timez.Time],
    finished_at: opt[timez.Time],
    ok: opt[bool],
    checks: [domain.Check]
}

pub gc struct Halt {
    halted: bool,
    reason: str,
    changed_at: timez.Time
}

pub gc struct PolicyView {
    id: str,
    amount: int,
    season_cap: int,
    status: str,
    proposed_by: str,
    approvals: [str]
}

// Everything the ledger needs from storage. Postgres is the source of
// truth; Redis only mirrors the trading halt. `C` is the adapter's state.
pub gc struct LedgerStore[C] {
    context: C,

    current: fn(C) -> result[opt[domain.Season], str],
    by_ordinal: fn(C, int) -> result[opt[domain.Season], str],
    open_seasons: fn(C) -> result[[domain.Season], str],

    // Session advisory locks on a connection held for the lease: only one
    // instance runs each background job at a time.
    lease_try: fn(C, int) -> result[opt[int], str],
    lease_release: fn(C, int),

    tick: fn(C, timez.Time, timez.Time) -> result[TickReport, str],

    grant_run: fn(C, str) -> result[GrantRun, str],
    eligible_after: fn(C, str, int) -> result[[str], str],
    grant_chunk: fn(C, str, [str]) -> result[ChunkResult, str],
    grant_advance: fn(C, str, str) -> result[bool, str],
    grant_finish: fn(C, str, str) -> result[GrantRun, str],

    balance: fn(C, str, int) -> result[opt[Balance], str],
    ledger_page: fn(C, str, int, str, int) -> result[opt[LedgerPage], str],

    recon_request: fn(C, str) -> result[str, str],
    recon_run: fn(C, bool) -> result[opt[ReconRun], str],
    recon_latest: fn(C) -> result[opt[ReconRun], str],
    last_full_recon: fn(C) -> result[opt[timez.Time], str],
    aggregate: fn(C) -> result[int, str],

    halt_state: fn(C) -> result[Halt, str],
    halt_clear: fn(C, str, str) -> result[bool, str],

    policy_propose: fn(C, int, int, str) -> result[str, str],
    policy_approve: fn(C, str, str) -> result[PolicyView, str],
    policies: fn(C) -> result[[PolicyView], str]
}

import "../domain" as core;

pub gc struct MarketLease {
    market_id: str,
    renewed: bool
}

pub gc struct Heartbeat {
    node_live: bool,
    markets: [MarketLease]
}

pub gc struct Claim {
    market_id: str,
    node_id: str,
    epoch: int,
    acquired: bool,
    renewed: bool
}

pub gc struct OwnershipStore[C] {
    context: C,
    candidates: fn(C, str, int) -> result[[str], str],
    register_node: fn(C, str, str, int) -> result[bool, str],
    heartbeat: fn(C, str, int, [str], [int]) -> result[Heartbeat, str],
    acquire: fn(C, str, str, int) -> result[Claim, str],
    mark_ready: fn(C, str, str, int) -> result[bool, str],
    release: fn(C, str, str, int) -> result[bool, str]
}

pub gc struct QueuedCommand {
    command_ref: str,
    command_id: int,
    command_type: str,
    order_id: str,
    source_key: str,
    queue_bucket: int,
    payload: str
}

pub gc struct CommandBatch {
    frontier: int,
    commands: [QueuedCommand]
}

pub gc struct EnqueueCommand {
    market_id: str,
    command_ref: str,
    command_type: str,
    order_id: str,
    source_key: str,
    payload: str,
    bucket_start: int
}

pub gc struct EnqueueResult {
    command_ref: str,
    queue_bucket: int,
    existing: bool
}

pub gc struct CommandQueue[C] {
    context: C,
    enqueue_control: fn(C, EnqueueCommand) -> result[EnqueueResult, str],
    enqueue_cancel: fn(C, str, str, str, str, str, str) -> result[EnqueueResult, str],
    enqueue_cancel_owned: fn(C, str, str, str) -> result[EnqueueResult, str],
    load_pending: fn(C, str, int, int) -> result[CommandBatch, str],
    sync_lifecycle: fn(C, str) -> result[int, str]
}

pub gc struct ActorWriter[C] {
    context: C,
    commit: fn(C, Record, core.Command, str, int) -> result[bool, str]
}

pub gc struct AdmissionRequest {
    market_id: str,
    account_id: str,
    order_id: str,
    command_ref: str,
    idem_key: str,
    intent_hash: str,
    original_intent: str,
    source_key: str,
    bucket_start: int,
    order: core.Order
}

pub gc struct AdmissionReceipt {
    order_id: str,
    command_ref: str,
    status: str,
    existing: bool
}

pub gc struct OrderAdmissionStore[C] {
    context: C,
    lookup: fn(C, str, str, str) -> result[opt[AdmissionReceipt], str],
    admit: fn(C, AdmissionRequest) -> result[AdmissionReceipt, str]
}

pub gc struct ReadOrder {
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

pub gc struct ReadOrdersPage {
    items: [ReadOrder],
    has_more: bool
}

pub gc struct ReadTrade {
    execution_seq: int,
    fill_index: int,
    mode: str,
    qty: int,
    yes_price: int,
    created_at: str
}

pub gc struct ReadCandle {
    bucket_at: str,
    open: int,
    high: int,
    low: int,
    close: int,
    volume: int
}

pub gc struct ReadTradesPage {
    items: [ReadTrade],
    has_more: bool
}

pub gc struct ReadStore[C] {
    context: C,
    order: fn(C, str, str) -> result[opt[ReadOrder], str],
    orders: fn(C, str, str, str, str, int) -> result[ReadOrdersPage, str],
    trades: fn(C, str, int, int, int) -> result[ReadTradesPage, str],
    history: fn(C, str, int, int) -> result[[ReadCandle], str]
}

pub gc struct BookViewStore[C] {
    context: C,
    ready_views: fn(C, str, int) -> result[[BookView], str]
}

pub gc struct RecoveryStep {
    seq: int,
    command_payload: str,
    transition_payload: str
}

pub gc struct RecoverySnapshot {
    committed_seq: int,
    state_hash: str,
    full_hash: str,
    schema_version: int,
    payload: str
}

pub gc struct RecoveryData {
    policy: core.Policy,
    pairs: int,
    committed_seq: int,
    rolling_hash: str,
    mode: str,
    base_seq: int,
    snapshots: [RecoverySnapshot],
    steps: [RecoveryStep]
}

pub gc struct SnapshotWrite {
    market_id: str,
    node_id: str,
    committed_seq: int,
    state_hash: str,
    full_hash: str,
    payload: str,
    owner_epoch: int
}

pub gc struct RecoveryStore[C] {
    context: C,
    load: fn(C, str) -> result[RecoveryData, str],
    save_snapshot: fn(C, SnapshotWrite) -> result[bool, str],
    reconcile_projection: fn(C, str, core.Snapshot) -> result[bool, str],
    verify_epoch: fn(C, SnapshotWrite, int, int) -> result[int, str],
    quarantine: fn(C, str, str, int, str) -> result[bool, str]
}

export type Sequence = string;
export type BookSide = "bid" | "ask";

export interface BookLevel {
  side: BookSide;
  yes_price: number;
  qty: string;
}

export interface BookSnapshotPayload {
  depth: number;
  value: number;
  price_band: {
    min: number;
    max: number;
    tick: number;
  };
  levels: BookLevel[];
}

export interface BookDeltaPayload {
  depth: number;
  levels: BookLevel[];
  view?: BookLevel[];
}

export interface StreamEnvelope<TType extends string, TPayload> {
  event_id: string;
  channel: string;
  type: TType;
  ts: string;
  payload: TPayload;
}

export interface BookSnapshotEvent
  extends StreamEnvelope<"book.snapshot", BookSnapshotPayload> {
  book_seq: Sequence;
  owner_epoch: Sequence;
}

export interface BookDeltaEvent
  extends StreamEnvelope<"book.delta", BookDeltaPayload> {
  book_seq: Sequence;
  from_seq?: Sequence;
  owner_epoch: Sequence;
}

export interface BookResetEvent
  extends StreamEnvelope<
    "book.reset",
    BookSnapshotPayload & { reason: string }
  > {
  book_seq: Sequence;
  owner_epoch: Sequence;
}

export type StreamEventType =
  | "book.snapshot"
  | "book.delta"
  | "book.reset"
  | "trade"
  | "market.status"
  | "cards.tick"
  | "season.started"
  | "season.closing"
  | "order.updated"
  | "balance.changed"
  | "position.changed"
  | "notification"
  | "resync_required"
  | "subscribed"
  | "unsubscribed"
  | "error"
  | "pong"
  | "stream.degraded"
  | "trades.gap"
  | "resync.begin"
  | "resync.complete"
  | "cards.refresh_required"
  | "season.refresh_required";

export interface DataStreamEvent
  extends StreamEnvelope<
    Exclude<
      StreamEventType,
      "book.snapshot" | "book.delta" | "book.reset"
    >,
    Record<string, unknown>
  > {
  book_seq?: Sequence;
  from_seq?: Sequence;
  owner_epoch?: Sequence;
  generation?: Sequence;
}

export type StreamEvent =
  | BookSnapshotEvent
  | BookDeltaEvent
  | BookResetEvent
  | DataStreamEvent;

export function isDataStreamEvent(
  event: StreamEvent,
): event is DataStreamEvent {
  return (
    event.type !== "book.snapshot" &&
    event.type !== "book.delta" &&
    event.type !== "book.reset"
  );
}

export interface SubscribeOperation {
  op: "subscribe" | "unsubscribe";
  channels: string[];
}

export interface ResyncOperation {
  op: "resync";
  channel: string;
  generation?: Sequence;
}

export interface PingOperation {
  op: "ping";
}

export type ClientOperation =
  | SubscribeOperation
  | ResyncOperation
  | PingOperation;

export class ProtocolError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ProtocolError";
  }
}

const UINT64_MAX = (1n << 64n) - 1n;
const SEQUENCE_PATTERN = /^(0|[1-9][0-9]*)$/;

export function parseSequence(value: unknown, field = "sequence"): bigint {
  if (typeof value !== "string" || !SEQUENCE_PATTERN.test(value)) {
    throw new ProtocolError(`${field} must be a canonical decimal string`);
  }
  const parsed = BigInt(value);
  if (parsed > UINT64_MAX) {
    throw new ProtocolError(`${field} exceeds uint64`);
  }
  return parsed;
}

export function parseStreamEvent(value: unknown): StreamEvent {
  if (!isRecord(value)) {
    throw new ProtocolError("event must be an object");
  }
  if (
    !isNonEmptyString(value.event_id) ||
    !isNonEmptyString(value.channel) ||
    !isNonEmptyString(value.type) ||
    !isNonEmptyString(value.ts) ||
    !isRecord(value.payload)
  ) {
    throw new ProtocolError("event is missing a valid envelope field");
  }
  if (!STREAM_EVENT_TYPES.has(value.type)) {
    throw new ProtocolError(`unsupported stream event type: ${value.type}`);
  }

  if (value.type === "book.snapshot" || value.type === "book.reset") {
    validateBookSequenceFields(value, false);
    validateSnapshotPayload(value.payload);
    if (value.type === "book.reset" && !isNonEmptyString(value.payload.reason)) {
      throw new ProtocolError("book.reset payload.reason must be non-empty");
    }
    return value as unknown as BookSnapshotEvent | BookResetEvent;
  }

  if (value.type === "book.delta") {
    validateBookSequenceFields(value, true);
    validateDeltaPayload(value.payload);
    return value as unknown as BookDeltaEvent;
  }

  for (const field of ["book_seq", "from_seq", "owner_epoch", "generation"]) {
    if (value[field] !== undefined) {
      parseSequence(value[field], field);
    }
  }
  return value as unknown as DataStreamEvent;
}

function validateBookSequenceFields(
  value: Record<string, unknown>,
  allowFromSequence: boolean,
): void {
  parseSequence(value.book_seq, "book_seq");
  parseSequence(value.owner_epoch, "owner_epoch");
  if (allowFromSequence && value.from_seq !== undefined) {
    const from = parseSequence(value.from_seq, "from_seq");
    if (from >= parseSequence(value.book_seq, "book_seq")) {
      throw new ProtocolError("from_seq must be less than book_seq");
    }
  } else if (!allowFromSequence && value.from_seq !== undefined) {
    throw new ProtocolError("from_seq is not valid on a snapshot or reset");
  }
}

const STREAM_EVENT_TYPES = new Set<string>([
  "book.snapshot",
  "book.delta",
  "book.reset",
  "trade",
  "market.status",
  "cards.tick",
  "season.started",
  "season.closing",
  "order.updated",
  "balance.changed",
  "position.changed",
  "notification",
  "resync_required",
  "subscribed",
  "unsubscribed",
  "error",
  "pong",
  "stream.degraded",
  "trades.gap",
  "resync.begin",
  "resync.complete",
  "cards.refresh_required",
  "season.refresh_required",
]);

function validateSnapshotPayload(
  payload: Record<string, unknown>,
): asserts payload is BookSnapshotPayload & Record<string, unknown> {
  validateDepth(payload.depth);
  const value = payload.value;
  if (!isIntegerInRange(value, 1, 0x7fffffff)) {
    throw new ProtocolError("book snapshot value must be a positive integer");
  }
  if (!isRecord(payload.price_band)) {
    throw new ProtocolError("book snapshot price_band is invalid");
  }
  const min = payload.price_band.min;
  const max = payload.price_band.max;
  const tick = payload.price_band.tick;
  if (!isIntegerInRange(min, 1, value)) {
    throw new ProtocolError("book snapshot price_band is invalid");
  }
  if (
    !isIntegerInRange(max, min, value) ||
    !isIntegerInRange(tick, 1, value) ||
    (max - min) % tick !== 0
  ) {
    throw new ProtocolError("book snapshot price_band is invalid");
  }
  validateLevels(payload.levels, max, false);
  validateCoverageDepth(payload.levels, payload.depth);
  for (const level of payload.levels) {
    if (
      level.yes_price < min ||
      (level.yes_price - min) % tick !== 0
    ) {
      throw new ProtocolError("book level is outside its price band or tick");
    }
  }
}

function validateDeltaPayload(payload: Record<string, unknown>): void {
  validateDepth(payload.depth);
  validateLevels(payload.levels, 0x7fffffff, true);
  if (payload.view !== undefined) {
    validateLevels(payload.view, 0x7fffffff, false);
    validateCoverageDepth(payload.view, payload.depth);
  }
}

function validateCoverageDepth(levels: BookLevel[], depth: number): void {
  for (const side of ["bid", "ask"] as const) {
    if (levels.filter((level) => level.side === side).length > depth) {
      throw new ProtocolError(`book view exceeds declared ${side} depth`);
    }
  }
}

function validateDepth(value: unknown): asserts value is number {
  if (!isIntegerInRange(value, 1, 50)) {
    throw new ProtocolError("book depth must be an integer from 1 to 50");
  }
}

function validateLevels(
  value: unknown,
  maxPrice: number,
  allowZeroQuantity: boolean,
): asserts value is BookLevel[] {
  if (!Array.isArray(value)) {
    throw new ProtocolError("book levels must be an array");
  }
  const seen = new Set<string>();
  for (const item of value) {
    if (
      !isRecord(item) ||
      (item.side !== "bid" && item.side !== "ask") ||
      !isIntegerInRange(item.yes_price, 1, maxPrice) ||
      typeof item.qty !== "string"
    ) {
      throw new ProtocolError("book level has an invalid side, price, or quantity");
    }
    const quantity = parseSequence(item.qty, "qty");
    if (!allowZeroQuantity && quantity === 0n) {
      throw new ProtocolError("snapshot book quantities must be positive");
    }
    const key = `${item.side}:${item.yes_price}`;
    if (seen.has(key)) {
      throw new ProtocolError("book levels contain a duplicate side and price");
    }
    seen.add(key);
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isNonEmptyString(value: unknown): value is string {
  return typeof value === "string" && value.length > 0;
}

function isIntegerInRange(
  value: unknown,
  min: number,
  max: number,
): value is number {
  return (
    typeof value === "number" &&
    Number.isInteger(value) &&
    value >= min &&
    value <= max
  );
}

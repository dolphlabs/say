import {
  parseSequence,
  ProtocolError,
  type BookDeltaEvent,
  type BookLevel,
  type BookResetEvent,
  type BookSide,
  type BookSnapshotEvent,
} from "./protocol.js";

export type MirrorState = "uninitialized" | "ready" | "stale";
export type ApplyResult = "applied" | "duplicate" | "resync";

export interface BookView {
  bids: BookLevel[];
  asks: BookLevel[];
  depth: number;
  value: number;
  price_band: {
    min: number;
    max: number;
    tick: number;
  };
  book_seq: string;
  owner_epoch: string;
}

export class BookMirror {
  private readonly onResync?: (channel: string, generation: number) => void;
  private readonly channel: string;
  readonly marketId: string;
  private levels = new Map<string, BookLevel>();
  private depth = 0;
  private value = 0;
  private priceBand = { min: 0, max: 0, tick: 0 };
  private sequence = 0n;
  private epoch = 0n;
  private syncGeneration = 0;
  private stateValue: MirrorState = "uninitialized";

  constructor(
    marketId: string,
    options: {
      onResync?: (channel: string, generation: number) => void;
    } = {},
  ) {
    this.marketId = marketId;
    this.channel = `market:${marketId}:book`;
    this.onResync = options.onResync;
  }

  get state(): MirrorState {
    return this.stateValue;
  }

  get bookSeq(): string | undefined {
    return this.stateValue === "ready" ? this.sequence.toString() : undefined;
  }

  get generation(): number {
    return this.syncGeneration;
  }

  beginResync(): number {
    this.syncGeneration += 1;
    this.stateValue = "stale";
    this.onResync?.(this.channel, this.syncGeneration);
    return this.syncGeneration;
  }

  installSnapshot(
    event: BookSnapshotEvent | BookResetEvent,
    generation = this.syncGeneration,
  ): boolean {
    if (generation !== this.syncGeneration) {
      return false;
    }
    this.assertChannel(event.channel);
    const snapshotSequence = parseSequence(event.book_seq, "book_seq");
    const snapshotEpoch = parseSequence(event.owner_epoch, "owner_epoch");
    if (
      this.stateValue !== "uninitialized" &&
      (snapshotEpoch < this.epoch ||
        (snapshotEpoch === this.epoch && snapshotSequence < this.sequence))
    ) {
      return false;
    }
    const newLevels = this.toMap(
      event.payload.levels,
      event.payload.price_band,
    );
    this.depth = event.payload.depth;
    this.value = event.payload.value;
    this.priceBand = { ...event.payload.price_band };
    this.sequence = snapshotSequence;
    this.epoch = snapshotEpoch;
    this.levels = newLevels;
    this.trimToDepth();
    this.stateValue = "ready";
    return true;
  }

  apply(event: BookDeltaEvent): ApplyResult {
    this.assertChannel(event.channel);
    if (this.stateValue !== "ready") {
      return this.requireResync();
    }

    const eventEpoch = parseSequence(event.owner_epoch, "owner_epoch");
    const eventSequence = parseSequence(event.book_seq, "book_seq");
    if (eventEpoch !== this.epoch) {
      return this.requireResync();
    }
    if (eventSequence <= this.sequence) {
      return "duplicate";
    }

    const baseSequence =
      event.from_seq === undefined
        ? eventSequence - 1n
        : parseSequence(event.from_seq, "from_seq");
    if (baseSequence !== this.sequence || event.payload.depth !== this.depth) {
      return this.requireResync();
    }

    if (event.payload.view !== undefined) {
      this.levels = this.toMap(event.payload.view, this.priceBand);
    } else {
      const updatedLevels = new Map(this.levels);
      for (const level of event.payload.levels) {
        if (
          level.yes_price < this.priceBand.min ||
          level.yes_price > this.priceBand.max ||
          (level.yes_price - this.priceBand.min) % this.priceBand.tick !== 0
        ) {
          throw new ProtocolError("book delta price is outside its price band or tick");
        }
        const key = levelKey(level.side, level.yes_price);
        if (level.qty === "0") {
          updatedLevels.delete(key);
        } else {
          updatedLevels.set(key, { ...level });
        }
      }
      if (this.windowChangedWithoutCoverage(updatedLevels)) {
        return this.requireResync();
      }
      this.levels = updatedLevels;
    }
    this.sequence = eventSequence;
    this.trimToDepth();
    return "applied";
  }

  yesView(): BookView {
    return this.view(this.sorted("bid"), this.sorted("ask"));
  }

  noView(): BookView {
    const bids = this.sorted("ask").map((level) => ({
      side: "bid" as const,
      yes_price: this.value - level.yes_price,
      qty: level.qty,
    }));
    const asks = this.sorted("bid").map((level) => ({
      side: "ask" as const,
      yes_price: this.value - level.yes_price,
      qty: level.qty,
    }));
    return this.view(
      sortLevels(bids, "bid"),
      sortLevels(asks, "ask"),
      {
        min: this.value - this.priceBand.max,
        max: this.value - this.priceBand.min,
        tick: this.priceBand.tick,
      },
    );
  }

  private view(
    bids: BookLevel[],
    asks: BookLevel[],
    priceBand = this.priceBand,
  ): BookView {
    if (this.stateValue !== "ready") {
      throw new Error("book mirror is not ready");
    }
    return {
      bids: bids.map((level) => ({ ...level })),
      asks: asks.map((level) => ({ ...level })),
      depth: this.depth,
      value: this.value,
      price_band: { ...priceBand },
      book_seq: this.sequence.toString(),
      owner_epoch: this.epoch.toString(),
    };
  }

  private sorted(side: BookSide): BookLevel[] {
    const levels = [...this.levels.values()].filter((level) => level.side === side);
    return sortLevels(levels, side).slice(0, this.depth);
  }

  private toMap(
    levels: BookLevel[],
    priceBand: { min: number; max: number; tick: number },
  ): Map<string, BookLevel> {
    const result = new Map<string, BookLevel>();
    for (const level of levels) {
      if (
        level.yes_price < priceBand.min ||
        level.yes_price > priceBand.max ||
        (level.yes_price - priceBand.min) % priceBand.tick !== 0 ||
        level.qty === "0"
      ) {
        throw new ProtocolError("book level is outside its price band or has zero quantity");
      }
      result.set(levelKey(level.side, level.yes_price), { ...level });
    }
    return result;
  }

  private trimToDepth(): void {
    const retained = new Map<string, BookLevel>();
    for (const side of ["bid", "ask"] as const) {
      const sorted = sortLevels(
        [...this.levels.values()].filter((candidate) => candidate.side === side),
        side,
      ).slice(0, this.depth);
      for (const level of sorted) {
        retained.set(levelKey(level.side, level.yes_price), level);
      }
    }
    this.levels = retained;
  }

  private windowChangedWithoutCoverage(
    updatedLevels: Map<string, BookLevel>,
  ): boolean {
    for (const side of ["bid", "ask"] as const) {
      const previous = [...this.levels.values()]
        .filter((level) => level.side === side)
        .map((level) => level.yes_price)
        .sort(side === "bid" ? (a, b) => b - a : (a, b) => a - b);
      if (previous.length < this.depth) {
        continue;
      }
      const updated = [...updatedLevels.values()]
        .filter((level) => level.side === side)
        .map((level) => level.yes_price)
        .sort(side === "bid" ? (a, b) => b - a : (a, b) => a - b)
        .slice(0, this.depth);
      if (
        previous.length !== updated.length ||
        previous.some((price, index) => price !== updated[index])
      ) {
        return true;
      }
    }
    return false;
  }

  private requireResync(): ApplyResult {
    if (this.stateValue !== "stale") {
      this.stateValue = "stale";
      this.syncGeneration += 1;
      this.onResync?.(this.channel, this.syncGeneration);
    }
    return "resync";
  }

  private assertChannel(channel: string): void {
    if (channel !== this.channel) {
      throw new ProtocolError(`book event channel does not match ${this.marketId}`);
    }
  }
}

function levelKey(side: BookSide, price: number): string {
  return `${side}:${price}`;
}

function sortLevels(levels: BookLevel[], side: BookSide): BookLevel[] {
  return levels.sort((left, right) =>
    side === "bid"
      ? right.yes_price - left.yes_price
      : left.yes_price - right.yes_price,
  );
}

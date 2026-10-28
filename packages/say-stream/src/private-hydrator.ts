import { parseSequence, type DataStreamEvent } from "./protocol.js";

export type PrivateHydrationState = "IDLE" | "STALE" | "LOADING" | "LIVE";
export type PrivateEntity = "orders" | "balance" | "positions";

export interface PrivateBaseline {
  revisions: Partial<Record<PrivateEntity, string>>;
}

export interface PrivateHydratorOptions {
  reload(): Promise<PrivateBaseline>;
  apply(event: DataStreamEvent): void;
  requestResync(): void;
  acknowledge(generation: string): void;
  onState?(state: PrivateHydrationState): void;
  onError?(error: Error): void;
  maxBufferedEvents?: number;
}

const PRIVATE_EVENT_TYPES = new Set([
  "order.updated",
  "balance.changed",
  "position.changed",
  "notification",
]);

export class PrivateHydrator {
  private readonly maxBufferedEvents: number;
  private readonly buffer: DataStreamEvent[] = [];
  private stateValue: PrivateHydrationState = "IDLE";
  private streamGeneration?: bigint;
  private operationGeneration = 0;
  private baseline?: Map<PrivateEntity, bigint>;
  private reloadReady = false;
  private completionReceived = false;

  constructor(private readonly options: PrivateHydratorOptions) {
    this.maxBufferedEvents = options.maxBufferedEvents ?? 10_000;
    if (
      !Number.isInteger(this.maxBufferedEvents) ||
      this.maxBufferedEvents < 1
    ) {
      throw new RangeError("maxBufferedEvents must be a positive integer");
    }
  }

  get state(): PrivateHydrationState {
    return this.stateValue;
  }

  handle(event: DataStreamEvent): void {
    if (event.channel !== "me") {
      return;
    }
    if (event.type === "resync_required") {
      this.invalidate("STALE");
      this.options.requestResync();
      return;
    }
    if (event.type === "resync.begin") {
      this.begin(event);
      return;
    }
    if (event.type === "resync.complete") {
      this.complete(event);
      return;
    }
    if (!PRIVATE_EVENT_TYPES.has(event.type)) {
      return;
    }
    this.receivePrivateEvent(event);
  }

  stop(): void {
    this.invalidate("IDLE");
  }

  private begin(event: DataStreamEvent): void {
    if (event.generation === undefined) {
      this.fail(new Error("resync.begin is missing its generation"));
      return;
    }
    this.operationGeneration += 1;
    const operationGeneration = this.operationGeneration;
    this.streamGeneration = parseSequence(event.generation, "generation");
    this.buffer.length = 0;
    this.baseline = undefined;
    this.reloadReady = false;
    this.completionReceived = false;
    this.setState("LOADING");
    void this.reload(operationGeneration, event.generation);
  }

  private async reload(
    operationGeneration: number,
    streamGeneration: string,
  ): Promise<void> {
    try {
      const baseline = await this.options.reload();
      if (operationGeneration !== this.operationGeneration) {
        return;
      }
      this.baseline = this.validateBaseline(baseline);
      this.reloadReady = true;
      this.options.acknowledge(streamGeneration);
      if (this.completionReceived) {
        this.finish();
      }
    } catch (error) {
      if (operationGeneration === this.operationGeneration) {
        this.fail(toError(error));
      }
    }
  }

  private complete(event: DataStreamEvent): void {
    if (
      event.generation === undefined ||
      this.streamGeneration !== parseSequence(event.generation, "generation")
    ) {
      return;
    }
    this.completionReceived = true;
    if (this.reloadReady) {
      this.finish();
    }
  }

  private receivePrivateEvent(event: DataStreamEvent): void {
    if (event.generation === undefined) {
      this.fail(new Error(`${event.type} is missing its generation`));
      return;
    }
    if (
      this.streamGeneration === undefined ||
      parseSequence(event.generation, "generation") !== this.streamGeneration
    ) {
      return;
    }
    if (this.stateValue === "LIVE" && this.baseline !== undefined) {
      try {
        this.applyIfNewer(event);
      } catch (error) {
        this.fail(toError(error));
      }
      return;
    }
    if (this.stateValue !== "LOADING" || this.buffer.length >= this.maxBufferedEvents) {
      this.fail(new Error("private hydration buffer is unavailable or full"));
      return;
    }
    this.buffer.push(event);
  }

  private finish(): void {
    if (this.baseline === undefined) {
      this.fail(new Error("private baseline is unavailable"));
      return;
    }
    try {
      for (const event of this.buffer) {
        this.applyIfNewer(event);
      }
      this.buffer.length = 0;
      this.setState("LIVE");
    } catch (error) {
      this.fail(toError(error));
    }
  }

  private applyIfNewer(event: DataStreamEvent): void {
    if (event.type === "notification") {
      this.options.apply(event);
      return;
    }

    const entity = entityFor(event.type);
    const revision = event.payload.revision;
    if (entity === undefined || revision === undefined) {
      throw new Error(`${event.type} is missing its entity revision`);
    }
    const nextRevision = parseSequence(revision, "revision");
    const currentRevision = this.baseline?.get(entity);
    if (currentRevision === undefined) {
      throw new Error(`private baseline is missing the ${entity} revision`);
    }
    if (nextRevision <= currentRevision) {
      return;
    }
    this.options.apply(event);
    this.baseline?.set(entity, nextRevision);
  }

  private validateBaseline(
    baseline: PrivateBaseline,
  ): Map<PrivateEntity, bigint> {
    if (
      typeof baseline !== "object" ||
      baseline === null ||
      typeof baseline.revisions !== "object" ||
      baseline.revisions === null
    ) {
      throw new Error("private reload returned an invalid baseline");
    }
    const result = new Map<PrivateEntity, bigint>();
    for (const entity of ["orders", "balance", "positions"] as const) {
      const revision = baseline.revisions[entity];
      if (revision === undefined) {
        throw new Error(`private reload is missing the ${entity} revision`);
      }
      result.set(entity, parseSequence(revision, `${entity} revision`));
    }
    return result;
  }

  private fail(error: Error, requestResync = true): void {
    this.invalidate("STALE");
    this.options.onError?.(error);
    if (requestResync) {
      this.options.requestResync();
    }
  }

  private invalidate(state: PrivateHydrationState): void {
    this.operationGeneration += 1;
    this.streamGeneration = undefined;
    this.baseline = undefined;
    this.reloadReady = false;
    this.completionReceived = false;
    this.buffer.length = 0;
    this.setState(state);
  }

  private setState(state: PrivateHydrationState): void {
    this.stateValue = state;
    this.options.onState?.(state);
  }
}

function entityFor(eventType: string): PrivateEntity | undefined {
  switch (eventType) {
    case "order.updated":
      return "orders";
    case "balance.changed":
      return "balance";
    case "position.changed":
      return "positions";
    default:
      return undefined;
  }
}

function toError(error: unknown): Error {
  return error instanceof Error ? error : new Error(String(error));
}

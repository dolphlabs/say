export interface PollingFallbackOptions<T> {
  fetch(signal: AbortSignal): Promise<T>;
  onValue(value: T): void;
  onError(error: Error): void;
  intervalMs?: number;
  random?(): number;
  setTimer?(callback: () => void, delayMs: number): ReturnType<typeof setTimeout>;
  clearTimer?(timer: ReturnType<typeof setTimeout>): void;
}

export class PollingFallback<T> {
  private readonly intervalMs: number;
  private readonly random: () => number;
  private readonly setTimer: (
    callback: () => void,
    delayMs: number,
  ) => ReturnType<typeof setTimeout>;
  private readonly clearTimer: (
    timer: ReturnType<typeof setTimeout>,
  ) => void;
  private running = false;
  private generation = 0;
  private timer?: ReturnType<typeof setTimeout>;
  private controller?: AbortController;
  private pendingGeneration?: number;

  constructor(private readonly options: PollingFallbackOptions<T>) {
    this.intervalMs = options.intervalMs ?? 5_000;
    if (!Number.isInteger(this.intervalMs) || this.intervalMs < 1) {
      throw new RangeError("intervalMs must be a positive integer");
    }
    this.random = options.random ?? Math.random;
    this.setTimer =
      options.setTimer ??
      ((callback, delayMs) => globalThis.setTimeout(callback, delayMs));
    this.clearTimer =
      options.clearTimer ??
      ((timer) => globalThis.clearTimeout(timer));
  }

  start(): void {
    if (this.running) {
      return;
    }
    this.running = true;
    this.generation += 1;
    if (this.controller) {
      this.pendingGeneration = this.generation;
      this.controller.abort();
      return;
    }
    void this.poll(this.generation);
  }

  invalidatePending(): void {
    if (!this.running) {
      return;
    }
    this.generation += 1;
    this.cancelTimer();
    if (this.controller) {
      this.pendingGeneration = this.generation;
      this.controller.abort();
    } else {
      void this.poll(this.generation);
    }
  }

  stop(): void {
    this.running = false;
    this.generation += 1;
    this.controller?.abort();
    this.pendingGeneration = undefined;
    this.cancelTimer();
  }

  private async poll(generation: number): Promise<void> {
    const controller = new AbortController();
    this.controller = controller;
    try {
      const value = await this.options.fetch(controller.signal);
      if (this.running && generation === this.generation) {
        this.options.onValue(value);
      }
    } catch (error) {
      if (
        this.running &&
        generation === this.generation &&
        !controller.signal.aborted
      ) {
        this.options.onError(toError(error));
      }
    } finally {
      if (this.controller === controller) {
        this.controller = undefined;
      }
      if (
        this.running &&
        this.pendingGeneration === this.generation &&
        this.controller === undefined
      ) {
        const nextGeneration = this.pendingGeneration;
        this.pendingGeneration = undefined;
        void this.poll(nextGeneration);
        return;
      }
      if (this.running && generation === this.generation) {
        this.schedule(generation);
      }
    }
  }

  private schedule(generation: number): void {
    const jitter = 0.8 + this.random() * 0.4;
    const delay = Math.max(1, Math.round(this.intervalMs * jitter));
    this.timer = this.setTimer(() => {
      this.timer = undefined;
      if (this.running && generation === this.generation) {
        void this.poll(generation);
      }
    }, delay);
  }

  private cancelTimer(): void {
    if (this.timer !== undefined) {
      this.clearTimer(this.timer);
      this.timer = undefined;
    }
  }
}

function toError(error: unknown): Error {
  return error instanceof Error ? error : new Error(String(error));
}

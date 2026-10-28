import { EventDeduplicator } from "./event-deduplicator.js";
import {
  parseSequence,
  parseStreamEvent,
  ProtocolError,
  type ClientOperation,
  type StreamEvent,
} from "./protocol.js";

export type ConnectionState =
  | "DISCONNECTED"
  | "CONNECTING"
  | "LIVE"
  | "DEGRADED"
  | "RESYNCING";

export interface StreamSocket {
  send(data: string): void;
  close(code?: number, reason?: string): void;
  onOpen(listener: () => void): () => void;
  onMessage(listener: (data: unknown) => void): () => void;
  onClose(listener: (code: number, reason: string) => void): () => void;
  onError(listener: (error: unknown) => void): () => void;
}

export interface StreamConnectionOptions {
  getUrl(anonymous: boolean): string | Promise<string>;
  socketFactory(url: string): StreamSocket;
  onEvent(event: StreamEvent): void;
  onState?(state: ConnectionState): void;
  onError?(error: Error): void;
  onReauthenticate?(): void;
  random?(): number;
  setTimer?(callback: () => void, delayMs: number): ReturnType<typeof setTimeout>;
  clearTimer?(timer: ReturnType<typeof setTimeout>): void;
}

const CHANNEL_PATTERN =
  /^(cards|season|me|market:[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}:(book|trades|status))$/;
const MAX_CHANNELS = 50;

export class StreamConnection {
  private readonly desiredChannels = new Set<string>();
  private readonly resyncChannels = new Set<string>();
  private readonly deduplicator = new EventDeduplicator();
  private readonly random: () => number;
  private readonly setTimer: (
    callback: () => void,
    delayMs: number,
  ) => ReturnType<typeof setTimeout>;
  private readonly clearTimer: (
    timer: ReturnType<typeof setTimeout>,
  ) => void;
  private socket?: StreamSocket;
  private detachListeners: Array<() => void> = [];
  private reconnectTimer?: ReturnType<typeof setTimeout>;
  private stableTimer?: ReturnType<typeof setTimeout>;
  private generation = 0;
  private retryCount = 0;
  private anonymous = false;
  private disposed = false;
  private stateValue: ConnectionState = "DISCONNECTED";

  constructor(private readonly options: StreamConnectionOptions) {
    this.random = options.random ?? Math.random;
    this.setTimer =
      options.setTimer ??
      ((callback, delayMs) => globalThis.setTimeout(callback, delayMs));
    this.clearTimer =
      options.clearTimer ??
      ((timer) => globalThis.clearTimeout(timer));
  }

  get state(): ConnectionState {
    return this.stateValue;
  }

  get channels(): readonly string[] {
    return [...this.desiredChannels];
  }

  connect(): void {
    if (this.disposed || this.stateValue === "CONNECTING" || this.socket) {
      return;
    }
    this.cancelReconnect();
    const generation = ++this.generation;
    this.setState("CONNECTING");
    void this.open(generation);
  }

  subscribe(channels: string[]): void {
    const additions = [...new Set(channels)].filter(
      (channel) => !this.desiredChannels.has(channel),
    );
    for (const channel of additions) {
      this.validateChannel(channel);
    }
    if (this.desiredChannels.size + additions.length > MAX_CHANNELS) {
      throw new RangeError(`at most ${MAX_CHANNELS} channels may be subscribed`);
    }
    for (const channel of additions) {
      this.desiredChannels.add(channel);
    }
    if (additions.length > 0) {
      this.send({ op: "subscribe", channels: additions });
    }
  }

  unsubscribe(channels: string[]): void {
    const removals = [...new Set(channels)].filter((channel) =>
      this.desiredChannels.has(channel),
    );
    for (const channel of removals) {
      this.desiredChannels.delete(channel);
    }
    if (removals.length > 0) {
      this.send({ op: "unsubscribe", channels: removals });
    }
  }

  resync(channel: string, generation?: string): void {
    if (!this.desiredChannels.has(channel)) {
      throw new RangeError("cannot resync a channel that is not subscribed");
    }
    if (generation !== undefined) {
      parseSequence(generation, "generation");
    }
    this.resyncChannels.add(channel);
    this.setState("RESYNCING");
    this.send({
      op: "resync",
      channel,
      ...(generation === undefined ? {} : { generation }),
    });
  }

  ping(): void {
    this.send({ op: "ping" });
  }

  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    this.generation += 1;
    this.cancelReconnect();
    this.cancelStableTimer();
    this.detachSocket();
    const socket = this.socket;
    this.socket = undefined;
    socket?.close(1000, "client disposed");
    this.desiredChannels.clear();
    this.resyncChannels.clear();
    this.deduplicator.clear();
    this.setState("DISCONNECTED");
  }

  private async open(generation: number): Promise<void> {
    try {
      const url = await this.options.getUrl(this.anonymous);
      if (!this.isCurrent(generation)) {
        return;
      }
      const socket = this.options.socketFactory(url);
      if (!this.isCurrent(generation)) {
        socket.close(1000, "stale connection attempt");
        return;
      }
      this.socket = socket;
      this.bind(socket, generation);
    } catch (error) {
      if (this.isCurrent(generation)) {
        const failedSocket = this.socket;
        this.socket = undefined;
        this.detachSocket();
        failedSocket?.close(1011, "failed to initialize stream socket");
        this.options.onError?.(toError(error));
        this.setState("DEGRADED");
        this.scheduleReconnect();
      }
    }
  }

  private bind(socket: StreamSocket, generation: number): void {
    const listeners: Array<() => void> = [];
    try {
      listeners.push(socket.onOpen(() => {
        if (!this.isCurrentSocket(socket, generation)) {
          return;
        }
        this.cancelStableTimer();
        this.stableTimer = this.setTimer(() => {
          this.stableTimer = undefined;
          if (this.isCurrentSocket(socket, generation)) {
            this.retryCount = 0;
          }
        }, 30_000);
        this.setState("LIVE");
        this.sendDesiredChannels();
      }));
      listeners.push(socket.onMessage((data) => {
        if (this.isCurrentSocket(socket, generation)) {
          this.receive(data);
        }
      }));
      listeners.push(socket.onClose((code, reason) => {
        if (!this.isCurrentSocket(socket, generation)) {
          return;
        }
        this.cancelStableTimer();
        this.detachSocket();
        this.socket = undefined;
        this.resyncChannels.clear();
        if (code === 4001) {
          this.anonymous = true;
          this.desiredChannels.delete("me");
          this.deduplicator.clear();
          try {
            this.options.onReauthenticate?.();
          } catch (error) {
            this.options.onError?.(toError(error));
          }
        }
        this.setState(code === 4008 ? "DEGRADED" : "DISCONNECTED");
        if (!this.disposed) {
          this.scheduleReconnect();
        }
        if (reason.length > 0 && code !== 1000 && code !== 4001 && code !== 4008) {
          this.options.onError?.(
            new Error(`stream closed with code ${code}: ${reason}`),
          );
        }
      }));
      listeners.push(socket.onError((error) => {
        if (this.isCurrentSocket(socket, generation)) {
          this.options.onError?.(toError(error));
        }
      }));
      this.detachListeners = listeners;
    } catch (error) {
      for (const detach of listeners) {
        detach();
      }
      throw error;
    }
  }

  private receive(data: unknown): void {
    if (typeof data !== "string") {
      this.options.onError?.(new ProtocolError("stream message must be text"));
      return;
    }

    let raw: unknown;
    try {
      raw = JSON.parse(data);
    } catch (error) {
      this.options.onError?.(
        new ProtocolError(`stream message is not valid JSON: ${toError(error).message}`),
      );
      return;
    }

    let event: StreamEvent;
    try {
      event = parseStreamEvent(raw);
    } catch (error) {
      this.options.onError?.(toError(error));
      const channel = isRecord(raw) ? raw.channel : undefined;
      if (
        typeof channel === "string" &&
        channel.endsWith(":book") &&
        this.desiredChannels.has(channel)
      ) {
        this.resync(channel);
      }
      return;
    }

    if (!this.deduplicator.accept(event.event_id)) {
      return;
    }
    if (
      (event.type === "book.snapshot" || event.type === "book.reset") &&
      this.resyncChannels.delete(event.channel) &&
      this.resyncChannels.size === 0
    ) {
      this.setState("LIVE");
    }
    if (
      event.type === "resync.complete" &&
      event.channel === "me" &&
      this.resyncChannels.delete("me") &&
      this.resyncChannels.size === 0
    ) {
      this.setState("LIVE");
    }
    try {
      this.options.onEvent(event);
    } catch (error) {
      this.options.onError?.(toError(error));
    }
  }

  private sendDesiredChannels(): void {
    const channels = [...this.desiredChannels];
    for (let offset = 0; offset < channels.length; offset += MAX_CHANNELS) {
      this.send({
        op: "subscribe",
        channels: channels.slice(offset, offset + MAX_CHANNELS),
      });
    }
  }

  private send(operation: ClientOperation): void {
    if (
      !this.socket ||
      (this.stateValue !== "LIVE" && this.stateValue !== "RESYNCING")
    ) {
      return;
    }
    try {
      this.socket.send(JSON.stringify(operation));
    } catch (error) {
      this.options.onError?.(toError(error));
      this.socket.close(1011, "failed to write stream operation");
    }
  }

  private scheduleReconnect(): void {
    if (this.disposed || this.reconnectTimer !== undefined) {
      return;
    }
    const baseDelay = Math.min(1_000 * 2 ** this.retryCount, 30_000);
    this.retryCount += 1;
    const jitteredDelay = Math.max(
      1_000,
      Math.min(30_000, Math.round(baseDelay * (0.8 + this.random() * 0.4))),
    );
    this.reconnectTimer = this.setTimer(() => {
      this.reconnectTimer = undefined;
      this.connect();
    }, jitteredDelay);
  }

  private cancelReconnect(): void {
    if (this.reconnectTimer !== undefined) {
      this.clearTimer(this.reconnectTimer);
      this.reconnectTimer = undefined;
    }
  }

  private cancelStableTimer(): void {
    if (this.stableTimer !== undefined) {
      this.clearTimer(this.stableTimer);
      this.stableTimer = undefined;
    }
  }

  private detachSocket(): void {
    for (const detach of this.detachListeners) {
      detach();
    }
    this.detachListeners = [];
  }

  private setState(state: ConnectionState): void {
    this.stateValue = state;
    this.options.onState?.(state);
  }

  private isCurrent(generation: number): boolean {
    return !this.disposed && generation === this.generation;
  }

  private isCurrentSocket(socket: StreamSocket, generation: number): boolean {
    return this.isCurrent(generation) && this.socket === socket;
  }

  private validateChannel(channel: string): void {
    if (!CHANNEL_PATTERN.test(channel)) {
      throw new ProtocolError(`invalid stream channel: ${channel}`);
    }
  }
}

export function browserSocketFactory(url: string): StreamSocket {
  const socket = new WebSocket(url);
  return {
    send: (data) => socket.send(data),
    close: (code, reason) => socket.close(code, reason),
    onOpen(listener) {
      socket.addEventListener("open", listener);
      return () => socket.removeEventListener("open", listener);
    },
    onMessage(listener) {
      const handler = (event: MessageEvent) => listener(event.data);
      socket.addEventListener("message", handler);
      return () => socket.removeEventListener("message", handler);
    },
    onClose(listener) {
      const handler = (event: CloseEvent) => listener(event.code, event.reason);
      socket.addEventListener("close", handler);
      return () => socket.removeEventListener("close", handler);
    },
    onError(listener) {
      const handler = (event: Event) => listener(event);
      socket.addEventListener("error", handler);
      return () => socket.removeEventListener("error", handler);
    },
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function toError(error: unknown): Error {
  return error instanceof Error ? error : new Error(String(error));
}

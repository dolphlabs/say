import assert from "node:assert/strict";
import test from "node:test";
import { StreamConnection } from "../dist/connection.js";

class FakeSocket {
  sent = [];
  listeners = new Map();
  closed;

  send(data) {
    this.sent.push(data);
  }

  close(code = 1000, reason = "") {
    this.closed = { code, reason };
  }

  onOpen(listener) {
    return this.add("open", listener);
  }

  onMessage(listener) {
    return this.add("message", listener);
  }

  onClose(listener) {
    return this.add("close", listener);
  }

  onError(listener) {
    return this.add("error", listener);
  }

  add(type, listener) {
    const listeners = this.listeners.get(type) ?? new Set();
    listeners.add(listener);
    this.listeners.set(type, listeners);
    return () => listeners.delete(listener);
  }

  emit(type, ...args) {
    for (const listener of this.listeners.get(type) ?? []) {
      listener(...args);
    }
  }
}

const bookChannel =
  "market:123e4567-e89b-42d3-a456-426614174000:book";

async function settle() {
  await Promise.resolve();
  await Promise.resolve();
}

test("restores desired subscriptions and deduplicates received events", async () => {
  const sockets = [];
  const events = [];
  const connection = new StreamConnection({
    getUrl: () => "wss://example.test/v1/stream",
    socketFactory: () => {
      const socket = new FakeSocket();
      sockets.push(socket);
      return socket;
    },
    onEvent: (event) => events.push(event),
    random: () => 0.5,
  });
  connection.subscribe(["cards", bookChannel]);
  connection.connect();
  await settle();
  assert.equal(connection.state, "CONNECTING");
  assert.deepEqual(sockets[0].sent, []);

  sockets[0].emit("open");
  assert.equal(connection.state, "LIVE");
  assert.deepEqual(JSON.parse(sockets[0].sent[0]), {
    op: "subscribe",
    channels: ["cards", bookChannel],
  });
  const event = {
    event_id: "event-1",
    channel: "cards",
    type: "cards.tick",
    ts: "2026-10-27T12:00:00Z",
    payload: { cards: [] },
  };
  sockets[0].emit("message", JSON.stringify(event));
  sockets[0].emit("message", JSON.stringify(event));
  assert.equal(events.length, 1);
  connection.dispose();
});

test("revocation removes private subscriptions and reconnects anonymously", async () => {
  const sockets = [];
  const urls = [];
  const timers = [];
  let reauthCount = 0;
  const connection = new StreamConnection({
    getUrl: (anonymous) => {
      urls.push(anonymous);
      return `wss://example.test/v1/stream?anonymous=${anonymous}`;
    },
    socketFactory: () => {
      const socket = new FakeSocket();
      sockets.push(socket);
      return socket;
    },
    onEvent: () => {},
    onReauthenticate: () => {
      reauthCount += 1;
    },
    random: () => 0.5,
    setTimer: (callback, delay) => {
      const timer = { callback, delay };
      timers.push(timer);
      return timer;
    },
    clearTimer: (timer) => {
      timer.cancelled = true;
    },
  });
  connection.subscribe(["cards", "me"]);
  connection.connect();
  await settle();
  sockets[0].emit("open");
  sockets[0].emit("close", 4001, "session revoked");
  assert.equal(reauthCount, 1);
  assert.deepEqual(connection.channels, ["cards"]);
  const reconnectTimer = timers.find((timer) => !timer.cancelled);
  assert.equal(reconnectTimer.delay, 1_000);
  reconnectTimer.callback();
  await settle();
  assert.deepEqual(urls, [false, true]);
  sockets[1].emit("open");
  assert.deepEqual(JSON.parse(sockets[1].sent[0]), {
    op: "subscribe",
    channels: ["cards"],
  });
  connection.dispose();
});

test("validates channels and caps unique subscriptions", () => {
  const connection = new StreamConnection({
    getUrl: () => "wss://example.test/v1/stream",
    socketFactory: () => new FakeSocket(),
    onEvent: () => {},
  });
  assert.throws(() => connection.subscribe(["market:m_123:book"]), /invalid/);
  assert.throws(
    () =>
      connection.subscribe([
        "cards",
        "season",
        "me",
        ...Array.from(
          { length: 48 },
          (_, index) =>
          `market:123e4567-e89b-42d3-a456-4266141740${index.toString(16).padStart(2, "0")}:book`,
        ),
      ]),
    /at most 50/,
  );
  assert.deepEqual(connection.channels, []);
  connection.dispose();
});

test("dispose cancels reconnect work", async () => {
  const timers = [];
  const sockets = [];
  const connection = new StreamConnection({
    getUrl: () => "wss://example.test/v1/stream",
    socketFactory: () => {
      const socket = new FakeSocket();
      sockets.push(socket);
      return socket;
    },
    onEvent: () => {},
    setTimer: (callback, delay) => {
      const timer = { callback, delay };
      timers.push(timer);
      return timer;
    },
    clearTimer: (timer) => {
      timer.cancelled = true;
    },
  });
  connection.connect();
  await settle();
  sockets[0].emit("close", 4008, "slow consumer");
  connection.dispose();
  assert.equal(timers[0].cancelled, true);
  assert.equal(connection.state, "DISCONNECTED");
});

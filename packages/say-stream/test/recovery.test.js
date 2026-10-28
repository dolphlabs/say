import assert from "node:assert/strict";
import test from "node:test";
import { PrivateHydrator } from "../dist/private-hydrator.js";
import { PollingFallback } from "../dist/polling-fallback.js";

function privateEvent(type, generation, payload = {}) {
  return {
    event_id: `${type}-${generation}-${payload.revision ?? payload.id ?? "none"}`,
    channel: "me",
    type,
    generation,
    ts: "2026-10-27T12:00:00Z",
    payload,
  };
}

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
}

async function settle() {
  await Promise.resolve();
  await Promise.resolve();
}

test("private hydration buffers through reload and applies only newer revisions", async () => {
  const reload = deferred();
  const applied = [];
  const acknowledgements = [];
  const requested = [];
  const hydrator = new PrivateHydrator({
    reload: () => reload.promise,
    apply: (event) => applied.push(event),
    requestResync: () => requested.push(true),
    acknowledge: (generation) => acknowledgements.push(generation),
  });
  hydrator.handle(privateEvent("resync.begin", "7"));
  hydrator.handle(privateEvent("order.updated", "7", { revision: "4" }));
  hydrator.handle(privateEvent("order.updated", "7", { revision: "6" }));
  hydrator.handle(privateEvent("notification", "7", { id: "n1" }));
  hydrator.handle(privateEvent("resync.complete", "7"));
  reload.resolve({
    revisions: { orders: "5", balance: "8", positions: "2" },
  });
  await settle();
  assert.deepEqual(acknowledgements, ["7"]);
  assert.deepEqual(
    applied.map((event) => event.event_id),
    ["order.updated-7-6", "notification-7-n1"],
  );
  assert.equal(hydrator.state, "LIVE");
  assert.deepEqual(requested, []);
});

test("late private reload results cannot activate a newer generation", async () => {
  const reloads = [deferred(), deferred()];
  const acknowledgements = [];
  const applied = [];
  let requestIndex = 0;
  const hydrator = new PrivateHydrator({
    reload: () => reloads[requestIndex++].promise,
    apply: (event) => applied.push(event),
    requestResync: () => {},
    acknowledge: (generation) => acknowledgements.push(generation),
  });
  hydrator.handle(privateEvent("resync.begin", "1"));
  hydrator.handle(privateEvent("resync.begin", "2"));
  reloads[0].resolve({
    revisions: { orders: "1", balance: "1", positions: "1" },
  });
  await settle();
  assert.deepEqual(acknowledgements, []);
  reloads[1].resolve({
    revisions: { orders: "2", balance: "2", positions: "2" },
  });
  await settle();
  assert.deepEqual(acknowledgements, ["2"]);
  hydrator.handle(privateEvent("resync.complete", "2"));
  assert.equal(hydrator.state, "LIVE");
  assert.deepEqual(applied, []);
});

test("private buffer overflow invalidates hydration and requests resync", () => {
  const requested = [];
  const errors = [];
  const hydrator = new PrivateHydrator({
    reload: () => new Promise(() => {}),
    apply: () => {},
    requestResync: () => requested.push(true),
    acknowledge: () => {},
    onError: (error) => errors.push(error),
    maxBufferedEvents: 1,
  });
  hydrator.handle(privateEvent("resync.begin", "3"));
  hydrator.handle(privateEvent("notification", "3", { id: "first" }));
  hydrator.handle(privateEvent("notification", "3", { id: "second" }));
  assert.equal(hydrator.state, "STALE");
  assert.equal(errors.length, 1);
  assert.deepEqual(requested, [true]);
});

test("polling invalidates an aborted response without overlapping requests", async () => {
  const requests = [];
  const values = [];
  const timers = [];
  const poller = new PollingFallback({
    fetch: (signal) => {
      const request = deferred();
      requests.push({ ...request, signal });
      return request.promise;
    },
    onValue: (value) => values.push(value),
    onError: (error) => {
      throw error;
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
  poller.start();
  poller.invalidatePending();
  assert.equal(requests.length, 1);
  assert.equal(requests[0].signal.aborted, true);
  requests[0].resolve("stale");
  await settle();
  assert.equal(requests.length, 2);
  requests[1].resolve("current");
  await settle();
  assert.deepEqual(values, ["current"]);
  assert.equal(timers[0].delay, 5_000);
  poller.stop();
  assert.equal(timers[0].cancelled, true);
});

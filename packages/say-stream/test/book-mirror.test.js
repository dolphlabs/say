import assert from "node:assert/strict";
import test from "node:test";
import { BookMirror } from "../dist/book-mirror.js";
import {
  parseSequence,
  parseStreamEvent,
  ProtocolError,
} from "../dist/protocol.js";
import { EventDeduplicator } from "../dist/event-deduplicator.js";

const channel = "market:123e4567-e89b-42d3-a456-426614174000:book";

function snapshot({ seq = "10", epoch = "2", levels, value = 100 } = {}) {
  return {
    event_id: `snapshot-${seq}`,
    channel,
    type: "book.snapshot",
    book_seq: seq,
    owner_epoch: epoch,
    ts: "2026-10-27T12:00:00Z",
    payload: {
      depth: 2,
      value,
      price_band: { min: 1, max: value - 1, tick: 1 },
      levels: levels ?? [
        { side: "bid", yes_price: 40, qty: "5" },
        { side: "bid", yes_price: 45, qty: "3" },
        { side: "ask", yes_price: 60, qty: "8" },
        { side: "ask", yes_price: 55, qty: "2" },
      ],
    },
  };
}

function delta({ seq, from, epoch = "2", levels = [], view } = {}) {
  return {
    event_id: `delta-${seq}`,
    channel,
    type: "book.delta",
    book_seq: seq,
    ...(from === undefined ? {} : { from_seq: from }),
    owner_epoch: epoch,
    ts: "2026-10-27T12:00:01Z",
    payload: {
      depth: 2,
      levels,
      ...(view === undefined ? {} : { view }),
    },
  };
}

test("installs a snapshot and derives a sorted, mirrored No view", () => {
  const mirror = new BookMirror(channel.split(":")[1]);
  mirror.installSnapshot(parseStreamEvent(snapshot()));
  assert.equal(mirror.state, "ready");
  assert.deepEqual(
    mirror.yesView().bids.map((level) => level.yes_price),
    [45, 40],
  );
  assert.deepEqual(
    mirror.noView().bids.map((level) => level.yes_price),
    [45, 40],
  );
  assert.deepEqual(
    mirror.noView().asks.map((level) => level.yes_price),
    [55, 60],
  );
});

test("applies absolute changes and removes zero-quantity levels", () => {
  const mirror = new BookMirror(channel.split(":")[1]);
  mirror.installSnapshot(
    parseStreamEvent(
      snapshot({
        levels: [
          { side: "bid", yes_price: 40, qty: "5" },
          { side: "ask", yes_price: 60, qty: "8" },
          { side: "ask", yes_price: 55, qty: "2" },
        ],
      }),
    ),
  );
  const result = mirror.apply(
    parseStreamEvent(
      delta({
        seq: "11",
        levels: [
          { side: "bid", yes_price: 40, qty: "0" },
          { side: "ask", yes_price: 55, qty: "11" },
        ],
      }),
    ),
  );
  assert.equal(result, "applied");
  assert.equal(mirror.bookSeq, "11");
  assert.deepEqual(mirror.yesView().bids, []);
  assert.equal(mirror.yesView().asks[0].qty, "11");
});

test("requires an exact exclusive base sequence for merged deltas", () => {
  const mirror = new BookMirror(channel.split(":")[1]);
  mirror.installSnapshot(parseStreamEvent(snapshot()));
  assert.equal(
    mirror.apply(
      parseStreamEvent(
        delta({
          seq: "12",
          from: "10",
          levels: [{ side: "bid", yes_price: 45, qty: "7" }],
        }),
      ),
    ),
    "applied",
  );
  assert.equal(mirror.bookSeq, "12");
});

test("marks a gap stale and requests resync once until a new snapshot", () => {
  const requests = [];
  const mirror = new BookMirror(channel.split(":")[1], {
    onResync: (value) => requests.push(value),
  });
  mirror.installSnapshot(parseStreamEvent(snapshot()));
  assert.equal(
    mirror.apply(parseStreamEvent(delta({ seq: "12", levels: [] }))),
    "resync",
  );
  assert.equal(
    mirror.apply(parseStreamEvent(delta({ seq: "13", levels: [] }))),
    "resync",
  );
  assert.deepEqual(requests, [channel]);
  assert.equal(mirror.state, "stale");
  mirror.installSnapshot(parseStreamEvent(snapshot({ seq: "13" })));
  assert.equal(mirror.state, "ready");
});

test("ignores snapshots from an obsolete resync generation", () => {
  const mirror = new BookMirror(channel.split(":")[1]);
  mirror.installSnapshot(parseStreamEvent(snapshot()));
  const oldGeneration = mirror.beginResync();
  const currentGeneration = mirror.beginResync();
  assert.equal(
    mirror.installSnapshot(
      parseStreamEvent(snapshot({ seq: "11" })),
      oldGeneration,
    ),
    false,
  );
  assert.equal(
    mirror.installSnapshot(
      parseStreamEvent(snapshot({ seq: "12" })),
      currentGeneration,
    ),
    true,
  );
  assert.equal(mirror.bookSeq, "12");
});

test("does not roll back a book to an older snapshot", () => {
  const mirror = new BookMirror(channel.split(":")[1]);
  mirror.installSnapshot(parseStreamEvent(snapshot({ seq: "12" })));
  assert.equal(
    mirror.installSnapshot(parseStreamEvent(snapshot({ seq: "11" }))),
    false,
  );
  assert.equal(mirror.bookSeq, "12");
});

test("rejects a changed epoch and accepts an authoritative replacement view", () => {
  const mirror = new BookMirror(channel.split(":")[1]);
  mirror.installSnapshot(parseStreamEvent(snapshot()));
  assert.equal(
    mirror.apply(parseStreamEvent(delta({ seq: "11", epoch: "3" }))),
    "resync",
  );
  mirror.installSnapshot(parseStreamEvent(snapshot()));
  assert.equal(
    mirror.apply(
      parseStreamEvent(
        delta({
          seq: "11",
          view: [
            { side: "bid", yes_price: 48, qty: "9" },
            { side: "ask", yes_price: 52, qty: "6" },
          ],
        }),
      ),
    ),
    "applied",
  );
  assert.deepEqual(
    mirror.yesView().asks.map((level) => level.yes_price),
    [52],
  );
});

test("requires a replacement view when a full top-depth window changes", () => {
  const mirror = new BookMirror(channel.split(":")[1]);
  mirror.installSnapshot(parseStreamEvent(snapshot()));
  assert.equal(
    mirror.apply(
      parseStreamEvent(
        delta({
          seq: "11",
          levels: [{ side: "ask", yes_price: 55, qty: "0" }],
        }),
      ),
    ),
    "resync",
  );
  mirror.installSnapshot(parseStreamEvent(snapshot()));
  assert.equal(
    mirror.apply(
      parseStreamEvent(
        delta({
          seq: "11",
          levels: [{ side: "ask", yes_price: 55, qty: "0" }],
          view: [
            { side: "bid", yes_price: 45, qty: "3" },
            { side: "bid", yes_price: 40, qty: "5" },
            { side: "ask", yes_price: 60, qty: "8" },
            { side: "ask", yes_price: 62, qty: "4" },
          ],
        }),
      ),
    ),
    "applied",
  );
  assert.deepEqual(
    mirror.yesView().asks.map((level) => level.yes_price),
    [60, 62],
  );
});

test("ignores duplicate and older sequence frames", () => {
  const mirror = new BookMirror(channel.split(":")[1]);
  mirror.installSnapshot(parseStreamEvent(snapshot()));
  assert.equal(
    mirror.apply(
      parseStreamEvent(
        delta({
          seq: "10",
          from: "9",
          levels: [{ side: "bid", yes_price: 45, qty: "99" }],
        }),
      ),
    ),
    "duplicate",
  );
  assert.equal(mirror.yesView().bids[0].qty, "3");
});

test("rejects unsafe numeric sequences, noncanonical strings and malformed books", () => {
  assert.equal(parseSequence("18446744073709551615"), (1n << 64n) - 1n);
  assert.throws(() => parseSequence(9007199254740992), ProtocolError);
  assert.throws(() => parseSequence("01"), ProtocolError);
  assert.throws(
    () => parseStreamEvent({ ...snapshot(), type: "book.future" }),
    ProtocolError,
  );
  assert.throws(
    () =>
      parseStreamEvent(
        snapshot({
          levels: [
            { side: "bid", yes_price: 20, qty: "1" },
            { side: "bid", yes_price: 20, qty: "2" },
          ],
        }),
      ),
    ProtocolError,
  );
});

test("deduplicates within a bounded LRU and supports lifecycle reset", () => {
  const deduplicator = new EventDeduplicator(2);
  assert.equal(deduplicator.accept("a"), true);
  assert.equal(deduplicator.accept("a"), false);
  assert.equal(deduplicator.accept("b"), true);
  assert.equal(deduplicator.accept("c"), true);
  assert.equal(deduplicator.accept("a"), true);
  deduplicator.clear();
  assert.equal(deduplicator.accept("c"), true);
});

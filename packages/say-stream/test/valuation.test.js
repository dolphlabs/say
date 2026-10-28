import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import {
  computeMark,
  computePositionValuation,
  computeSummaryValuation,
  NotificationStore,
  PortfolioLive,
} from "../dist/index.js";

test("shared valuation vectors from spec/valuation-vectors.json", () => {
  const vectorsPath = path.resolve(process.cwd(), "../../spec/valuation-vectors.json");
  const data = JSON.parse(fs.readFileSync(vectorsPath, "utf8"));
  assert.ok(Array.isArray(data.vectors), "vectors must be an array");

  for (const v of data.vectors) {
    if (v.type === "summary") {
      const result = computeSummaryValuation({
        available: BigInt(v.input.available),
        held: BigInt(v.input.held),
        positionsValue: BigInt(v.input.positions_value),
        startingGrant: v.input.starting_grant !== null ? BigInt(v.input.starting_grant) : null,
      });
      assert.equal(
        result.total,
        BigInt(v.expected.total),
        `Vector ${v.name}: total mismatch`
      );
      if (v.expected.season_pnl === null) {
        assert.equal(result.seasonPnl, null, `Vector ${v.name}: expected null seasonPnl`);
      } else {
        assert.equal(
          result.seasonPnl,
          BigInt(v.expected.season_pnl),
          `Vector ${v.name}: seasonPnl mismatch`
        );
      }
    } else if (v.type === "position") {
      const result = computePositionValuation({
        redemptionUnits: BigInt(v.input.redemption_units),
        outcome: v.input.outcome,
        qty: BigInt(v.input.qty),
        costBasis: BigInt(v.input.cost_basis),
        lastPrice: v.input.last_price !== null ? BigInt(v.input.last_price) : null,
        bestBid: v.input.best_bid !== null ? BigInt(v.input.best_bid) : null,
        bestAsk: v.input.best_ask !== null ? BigInt(v.input.best_ask) : null,
      });

      assert.equal(
        result.mark.num,
        BigInt(v.expected.mark_num),
        `Vector ${v.name}: mark.num mismatch`
      );
      assert.equal(
        result.mark.den,
        BigInt(v.expected.mark_den),
        `Vector ${v.name}: mark.den mismatch`
      );
      assert.equal(
        result.markSource,
        v.expected.mark_source,
        `Vector ${v.name}: markSource mismatch`
      );
      assert.equal(
        result.value,
        BigInt(v.expected.value),
        `Vector ${v.name}: value mismatch`
      );
      assert.equal(
        result.unrealizedPnl,
        BigInt(v.expected.unrealized_pnl),
        `Vector ${v.name}: unrealizedPnl mismatch`
      );
      assert.equal(
        result.pnlPct,
        v.expected.pnl_pct,
        `Vector ${v.name}: pnlPct mismatch`
      );
    }
  }
});

test("NotificationStore dedupes and coalesces partial fills", () => {
  const store = new NotificationStore();
  let latestState = store.getState();
  const unsubscribe = store.subscribe((s) => {
    latestState = s;
  });

  assert.equal(latestState.items.length, 0);
  assert.equal(latestState.unreadCount, 0);

  // First partial fill
  store.handleEvent({
    id: "notif-1",
    kind: "order_filled",
    dedupe_key: "order_filled:order-123",
    title: "Order partly filled",
    body: "4 of 6 Enyimba Yes @ S 54. The rest is still waiting.",
  });

  assert.equal(latestState.items.length, 1);
  assert.equal(latestState.unreadCount, 1);
  assert.equal(latestState.items[0].body, "4 of 6 Enyimba Yes @ S 54. The rest is still waiting.");

  // User marks it read
  store.markRead(["notif-1"]);
  assert.equal(latestState.unreadCount, 0);
  assert.equal(latestState.items[0].unread, false);

  // Second partial fill with same dedupe_key: coalesces in place and marks unread again!
  store.handleEvent({
    id: "notif-1-updated",
    kind: "order_filled",
    dedupe_key: "order_filled:order-123",
    title: "Order partly filled",
    body: "5 of 6 Enyimba Yes @ S 54. The rest is still waiting.",
  });

  assert.equal(latestState.items.length, 1, "Must coalesce in place, length remains 1");
  assert.equal(latestState.unreadCount, 1, "Must be unread again");
  assert.equal(latestState.items[0].body, "5 of 6 Enyimba Yes @ S 54. The rest is still waiting.");

  // Mark all read
  store.markRead();
  assert.equal(latestState.unreadCount, 0);

  unsubscribe();
});

test("PortfolioLive updates on market price tick without roundtrip", async () => {
  const summaryFixture = {
    season: { ordinal: 1, status: "ACTIVE", ends_at: "2026-12-31T23:59:59Z" },
    available: 427n,
    held: 109n,
    held_shares: [],
    positions_value: 978n,
    total: 1514n,
    season_pnl: 514n,
    starting_grant: 1000n,
    rank: null,
  };

  const positionsFixture = [
    {
      market: {
        id: "mkt-1",
        slug: "enyimba-rivers",
        question: "Enyimba vs Rivers",
        category: "SPORTS",
        status: "OPEN",
        closes_at: "2026-12-31T23:59:59Z",
        redemption_units: 100n,
      },
      outcome: "YES",
      qty: 10n,
      qty_free: 10n,
      qty_in_orders: 0n,
      cost_basis: 500n,
      valuation: {
        mark: { num: 50n, den: 1n },
        markSource: "last_trade",
        value: 500n,
        unrealizedPnl: 0n,
        pnlPct: 0,
      },
    },
  ];

  const live = new PortfolioLive({
    fetchSummary: async () => summaryFixture,
    fetchPositions: async () => positionsFixture,
  });

  await live.load();
  assert.equal(live.getState().positions.length, 1);
  assert.equal(live.getState().positions[0].valuation.value, 500n);

  // Tick update: price moves to 60
  live.onMarketPriceUpdate("mkt-1", 60n, 58n, 62n);
  const updatedPos = live.getState().positions[0];
  assert.equal(updatedPos.valuation.value, 600n);
  assert.equal(updatedPos.valuation.unrealizedPnl, 100n);
  assert.equal(updatedPos.valuation.pnlPct, 20);

  // Total in summary should update: 427 + 109 + 600 = 1136
  assert.equal(live.getState().summary?.total, 1136n);

  live.dispose();
});

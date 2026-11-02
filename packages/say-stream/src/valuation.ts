// Valuation rules per Prompt 07 section 1:
// Single definition used by both server and client.

export type Outcome = "YES" | "NO";

export type MarkSource = "last_trade" | "mid" | "avg_cost";

export interface Rational {
  num: bigint;
  den: bigint;
}

export interface PositionValuationInput {
  redemptionUnits: bigint;
  outcome: Outcome;
  qty: bigint;
  costBasis: bigint;
  lastPrice: bigint | null;
  bestBid: bigint | null;
  bestAsk: bigint | null;
}

export interface PositionValuationResult {
  mark: Rational;
  markSource: MarkSource;
  value: bigint;
  unrealizedPnl: bigint;
  pnlPct: number | null;
}

export interface SummaryValuationInput {
  available: bigint;
  held: bigint;
  positionsValue: bigint;
  startingGrant: bigint | null;
}

export interface SummaryValuationResult {
  total: bigint;
  seasonPnl: bigint | null;
}

function gcd(a: bigint, b: bigint): bigint {
  let x = a < 0n ? -a : a;
  let y = b < 0n ? -b : b;
  while (y > 0n) {
    const t = y;
    y = x % y;
    x = t;
  }
  return x;
}

/**
 * Computes mark price and source for an open position:
 * 1. Last traded price (YES = lastPrice, NO = V - lastPrice).
 * 2. Midpoint of best bid and ask (rounded down). For NO, own_bid = V - Yes ask, own_ask = V - Yes bid.
 * 3. Average cost fallback: (cost_basis / qty).
 */
export function computeMark(
  redemptionUnits: bigint,
  outcome: Outcome,
  costBasis: bigint,
  qty: bigint,
  lastPrice: bigint | null,
  bestBid: bigint | null,
  bestAsk: bigint | null
): { mark: Rational; source: MarkSource } {
  // 1. Last traded price
  if (lastPrice !== null) {
    const ownPrice = outcome === "YES" ? lastPrice : redemptionUnits - lastPrice;
    return {
      mark: { num: ownPrice, den: 1n },
      source: "last_trade",
    };
  }

  // 2. Midpoint of bid and ask
  if (bestBid !== null && bestAsk !== null) {
    let ownBid: bigint;
    let ownAsk: bigint;
    if (outcome === "YES") {
      ownBid = bestBid;
      ownAsk = bestAsk;
    } else {
      ownBid = redemptionUnits - bestAsk;
      ownAsk = redemptionUnits - bestBid;
    }
    const mid = (ownBid + ownAsk) / 2n; // integer division truncates toward zero / rounds down for positive
    return {
      mark: { num: mid, den: 1n },
      source: "mid",
    };
  }

  // 3. Average cost fallback
  if (qty > 0n) {
    const g = gcd(costBasis, qty);
    return {
      mark: { num: costBasis / g, den: qty / g },
      source: "avg_cost",
    };
  }

  return {
    mark: { num: 0n, den: 1n },
    source: "avg_cost",
  };
}

/**
 * Computes position value and P/L:
 * - value = qty * mark (for avg_cost fallback, qty * (basis / qty) = basis exactly)
 * - unrealized_pnl = value - cost_basis
 * - pnl_pct = trunc_toward_zero(100 * unrealized_pnl / cost_basis)
 */
export function computePositionValuation(
  input: PositionValuationInput
): PositionValuationResult {
  const { mark, source } = computeMark(
    input.redemptionUnits,
    input.outcome,
    input.costBasis,
    input.qty,
    input.lastPrice,
    input.bestBid,
    input.bestAsk
  );

  let value: bigint;
  if (source === "avg_cost" && mark.den === input.qty && input.qty > 0n) {
    // Avoid rounding error: exact basis
    value = input.costBasis;
  } else {
    value = (input.qty * mark.num) / mark.den;
  }

  const unrealizedPnl = value - input.costBasis;

  let pnlPct: number | null = null;
  if (input.costBasis > 0n) {
    const pctBigInt = (100n * unrealizedPnl) / input.costBasis;
    pnlPct = Number(pctBigInt);
  }

  return {
    mark,
    markSource: source,
    value,
    unrealizedPnl,
    pnlPct,
  };
}

/**
 * Computes season total and P/L:
 * - total = available + held + positions_value
 * - season_pnl = total - starting_grant (if grant is present)
 */
export function computeSummaryValuation(
  input: SummaryValuationInput
): SummaryValuationResult {
  const total = input.available + input.held + input.positionsValue;
  const seasonPnl =
    input.startingGrant !== null ? total - input.startingGrant : null;

  return {
    total,
    seasonPnl,
  };
}

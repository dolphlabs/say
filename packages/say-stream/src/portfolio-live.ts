// Live portfolio manager per Prompt 07 section 5.
import {
  computePositionValuation,
  computeSummaryValuation,
  type Outcome,
  type PositionValuationResult,
} from "./valuation.js";

export interface PortfolioSummary {
  season: {
    ordinal: number;
    status: string;
    ends_at: string;
  };
  available: bigint;
  held: bigint;
  held_shares: Array<{ market_id: string; outcome: Outcome; qty: bigint }>;
  positions_value: bigint;
  total: bigint;
  season_pnl: bigint | null;
  starting_grant: bigint | null;
  rank: { position: number; of: number } | null;
}

export interface PositionItem {
  market: {
    id: string;
    slug: string;
    question: string;
    category: string;
    status: string;
    closes_at: string;
    redemption_units: bigint;
  };
  outcome: Outcome;
  qty: bigint;
  qty_free: bigint;
  qty_in_orders: bigint;
  cost_basis: bigint;
  valuation: PositionValuationResult;
  proposed_outcome?: Outcome;
}

export interface PortfolioLiveState {
  summary: PortfolioSummary | null;
  positions: PositionItem[];
  loading: boolean;
  error: string | null;
}

export type PortfolioLiveListener = (state: PortfolioLiveState) => void;

export interface PortfolioLiveOptions {
  fetchSummary: () => Promise<PortfolioSummary>;
  fetchPositions: () => Promise<PositionItem[]>;
  debounceMs?: number;
}

export class PortfolioLive {
  private state: PortfolioLiveState = {
    summary: null,
    positions: [],
    loading: true,
    error: null,
  };
  private listeners: Set<PortfolioLiveListener> = new Set();
  private debounceTimer: ReturnType<typeof setTimeout> | null = null;
  private readonly debounceMs: number;
  private readonly fetchSummary: () => Promise<PortfolioSummary>;
  private readonly fetchPositions: () => Promise<PositionItem[]>;
  private isDisposed: boolean = false;

  constructor(options: PortfolioLiveOptions) {
    this.fetchSummary = options.fetchSummary;
    this.fetchPositions = options.fetchPositions;
    this.debounceMs = options.debounceMs ?? 500;
  }

  public getState(): PortfolioLiveState {
    return { ...this.state };
  }

  public subscribe(listener: PortfolioLiveListener): () => void {
    this.listeners.add(listener);
    listener(this.getState());
    return () => {
      this.listeners.delete(listener);
    };
  }

  private notify(): void {
    const s = this.getState();
    for (const listener of this.listeners) {
      listener(s);
    }
  }

  /**
   * Initial or manual reload of portfolio.
   */
  public async load(): Promise<void> {
    if (this.isDisposed) return;
    this.state.loading = true;
    this.state.error = null;
    this.notify();

    try {
      const [summary, positions] = await Promise.all([
        this.fetchSummary(),
        this.fetchPositions(),
      ]);
      if (this.isDisposed) return;
      this.state.summary = summary;
      this.state.positions = positions;
      this.state.loading = false;
      this.notify();
    } catch (err) {
      if (this.isDisposed) return;
      this.state.loading = false;
      this.state.error = err instanceof Error ? err.message : String(err);
      this.notify();
    }
  }

  /**
   * Debounced refetch triggered on `position.changed` or `balance.changed`.
   */
  public onAccountEvent(): void {
    if (this.isDisposed) return;
    if (this.debounceTimer !== null) {
      clearTimeout(this.debounceTimer);
    }
    this.debounceTimer = setTimeout(() => {
      this.debounceTimer = null;
      void this.load();
    }, this.debounceMs);
  }

  /**
   * Live tick update from `cards.tick` or market price changes.
   * Updates marks and recalculates positions without database round-trip.
   */
  public onMarketPriceUpdate(
    marketId: string,
    lastPrice: bigint | null,
    bestBid: bigint | null,
    bestAsk: bigint | null
  ): void {
    if (this.isDisposed || this.state.positions.length === 0) return;

    let changed = false;
    let newPositionsValue = 0n;

    const newPositions = this.state.positions.map((pos) => {
      if (pos.market.id === marketId) {
        changed = true;
        const valuation = computePositionValuation({
          redemptionUnits: pos.market.redemption_units,
          outcome: pos.outcome,
          qty: pos.qty,
          costBasis: pos.cost_basis,
          lastPrice,
          bestBid,
          bestAsk,
        });
        newPositionsValue += valuation.value;
        return {
          ...pos,
          valuation,
        };
      } else {
        newPositionsValue += pos.valuation.value;
        return pos;
      }
    });

    if (changed) {
      this.state.positions = newPositions;
      if (this.state.summary) {
        const summaryValuation = computeSummaryValuation({
          available: this.state.summary.available,
          held: this.state.summary.held,
          positionsValue: newPositionsValue,
          startingGrant: this.state.summary.starting_grant,
        });
        this.state.summary = {
          ...this.state.summary,
          positions_value: newPositionsValue,
          total: summaryValuation.total,
          season_pnl: summaryValuation.seasonPnl,
        };
      }
      this.notify();
    }
  }

  public dispose(): void {
    this.isDisposed = true;
    if (this.debounceTimer !== null) {
      clearTimeout(this.debounceTimer);
      this.debounceTimer = null;
    }
    this.listeners.clear();
  }
}

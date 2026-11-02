import type { Book, Level } from '../markets/api'
import type { Outcome } from './api'

export type Ladder = { asks: Level[]; bids: Level[] }

// The book holds canonical YES levels; a NO price is the redemption value
// minus the YES price on the opposite side.
export function ladder(book: Book | undefined, outcome: Outcome, redemption: number): Ladder {
  if (!book) return { asks: [], bids: [] }
  const asks = [...book.asks].sort((a, b) => a.yes_price - b.yes_price)
  const bids = [...book.bids].sort((a, b) => b.yes_price - a.yes_price)
  if (outcome === 'YES') return { asks, bids }
  const flip = (l: Level) => ({ yes_price: redemption - l.yes_price, qty: l.qty })
  return { asks: bids.map(flip), bids: asks.map(flip) }
}

export type BuyEstimate = { shares: number; cost: number; worst: number | null; exhausted: boolean }

export function estimateBuy(asks: Level[], spend: number, fee: number): BuyEstimate {
  let budget = Math.max(0, spend - fee)
  let shares = 0
  let cost = 0
  let worst: number | null = null
  for (const level of asks) {
    const take = Math.min(level.qty, Math.floor(budget / level.yes_price))
    if (take <= 0) break
    shares += take
    cost += take * level.yes_price
    budget -= take * level.yes_price
    worst = level.yes_price
    if (take < level.qty) return { shares, cost, worst, exhausted: false }
  }
  return { shares, cost, worst, exhausted: budget > 0 && shares > 0 }
}

export type SellEstimate = { sold: number; proceeds: number; worst: number | null }

export function estimateSell(bids: Level[], qty: number): SellEstimate {
  let left = qty
  let proceeds = 0
  let worst: number | null = null
  for (const level of bids) {
    if (left <= 0) break
    const take = Math.min(left, level.qty)
    left -= take
    proceeds += take * level.yes_price
    worst = level.yes_price
  }
  return { sold: qty - left, proceeds, worst }
}

export const best = (levels: Level[]) => (levels.length ? levels[0].yes_price : null)

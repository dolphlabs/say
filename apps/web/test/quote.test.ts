import { describe, expect, it } from 'vitest'
import { estimateBuy, estimateSell, ladder } from '../src/features/trading/quote'
import type { Book } from '../src/features/markets/api'

const book: Book = {
  market_id: 'm',
  last_price: 57,
  health: 'READY',
  mode: 'OPEN',
  bids: [
    { yes_price: 55, qty: 90 },
    { yes_price: 56, qty: 120 },
  ],
  asks: [
    { yes_price: 59, qty: 110 },
    { yes_price: 58, qty: 80 },
  ],
}

describe('order quotes', () => {
  it('should sort the yes ladder best price first', () => {
    const { asks, bids } = ladder(book, 'YES', 100)
    expect(asks.map((l) => l.yes_price)).toEqual([58, 59])
    expect(bids.map((l) => l.yes_price)).toEqual([56, 55])
  })

  it('should mirror no prices around the redemption value', () => {
    const { asks, bids } = ladder(book, 'NO', 100)
    expect(asks).toEqual([
      { yes_price: 44, qty: 120 },
      { yes_price: 45, qty: 90 },
    ])
    expect(bids[0]).toEqual({ yes_price: 42, qty: 80 })
  })

  it('should keep the fee out of the spend and walk levels in order', () => {
    const asks = ladder(book, 'YES', 100).asks
    expect(estimateBuy(asks, 59, 1)).toEqual({ shares: 1, cost: 58, worst: 58, exhausted: false })
    const deep = estimateBuy(asks, 58 * 80 + 59 * 2 + 1, 1)
    expect(deep.shares).toBe(82)
    expect(deep.worst).toBe(59)
  })

  it('should report no shares when the spend is below one share', () => {
    expect(estimateBuy(ladder(book, 'YES', 100).asks, 10, 1).shares).toBe(0)
  })

  it('should report an exhausted book instead of inventing shares', () => {
    const result = estimateBuy([{ yes_price: 50, qty: 2 }], 1000, 1)
    expect(result).toMatchObject({ shares: 2, cost: 100, exhausted: true })
  })

  it('should only sell into existing bids', () => {
    const bids = ladder(book, 'YES', 100).bids
    expect(estimateSell(bids, 150)).toEqual({ sold: 150, proceeds: 120 * 56 + 30 * 55, worst: 55 })
    expect(estimateSell(bids, 500).sold).toBe(210)
    expect(estimateSell([], 5)).toEqual({ sold: 0, proceeds: 0, worst: null })
  })
})

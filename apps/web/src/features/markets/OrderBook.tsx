import { useState, type CSSProperties } from 'react'
import { isApiError } from '../../api'
import { clock, number, sedi } from '../../format'
import { Notice, Segmented, SidePill } from '../../ui/kit'
import type { Outcome } from '../trading/api'
import type { Prefill } from '../trading/OrderPanel'
import { best, ladder } from '../trading/quote'
import { tradeSide, useBook, useTrades, type Market } from './api'

const DEPTH = 5

export function OrderBook({ market, onPick }: { market: Market; onPick: (p: Omit<Prefill, 'nonce'>) => void }) {
  const [outcome, setOutcome] = useState<Outcome>('YES')
  const book = useBook(market.id)
  const V = market.redemption_units
  const { asks, bids } = ladder(book.data, outcome, V)
  const shownAsks = asks.slice(0, DEPTH)
  const shownBids = bids.slice(0, DEPTH)
  const deepest = Math.max(
    shownAsks.reduce((n, l) => n + l.qty, 0),
    shownBids.reduce((n, l) => n + l.qty, 0),
    1,
  )
  const bestAsk = best(asks)
  const bestBid = best(bids)
  const last = book.data?.last_price == null ? null : outcome === 'YES' ? book.data.last_price : V - book.data.last_price
  const word = outcome === 'YES' ? 'yes' : 'no'
  const other = outcome === 'YES' ? 'No' : 'Yes'
  const degraded = isApiError(book.error, 'MARKET_DEGRADED')

  let running = 0
  const askRows = shownAsks
    .map((l) => {
      running += l.qty
      return { ...l, depth: running }
    })
    .reverse()
  running = 0
  const bidRows = shownBids.map((l) => {
    running += l.qty
    return { ...l, depth: running }
  })

  return (
    <section className="panel book" aria-labelledby="book-h">
      <div className="panel-head">
        <h2 id="book-h">
          Order book {book.data && !degraded && <span className="live">Live</span>}
        </h2>
        <Segmented
          label="Book side"
          value={outcome}
          className={`small ${outcome === 'YES' ? 'yes' : 'no'}`}
          options={[
            ['YES', 'Yes'],
            ['NO', 'No'],
          ]}
          onChange={setOutcome}
        />
      </div>
      {degraded ? (
        <Notice>Live prices are catching up. The book will be back in a moment.</Notice>
      ) : book.error ? (
        <Notice error={book.error} />
      ) : !asks.length && !bids.length ? (
        <p className="muted">{book.isLoading ? 'Loading the book…' : 'No orders on the book yet. Place a limit order to set a price.'}</p>
      ) : (
        <>
          <div className="book-cols" aria-hidden="true">
            <span>Price</span>
            <span>Shares</span>
            <span>Total</span>
          </div>
          <div className="book-rows">
            {askRows.map((l) => (
              <button
                type="button"
                key={`a${l.yes_price}`}
                className="book-row ask"
                style={{ '--depth': `${Math.round((l.depth / deepest) * 100)}%` } as CSSProperties}
                aria-label={`Buy ${word} at S ${l.yes_price}, ${l.qty} shares`}
                disabled={market.status !== 'OPEN'}
                onClick={() => onPick({ side: 'BUY', outcome, type: 'limit', price: l.yes_price })}
              >
                <span className="price">S {l.yes_price}</span>
                <span>{number(l.qty)}</span>
                <span className="muted">{sedi(l.qty * l.yes_price)}</span>
              </button>
            ))}
            <div className="book-mid">
              <span>Last {sedi(last)}</span>
              <span>{bestAsk != null && bestBid != null ? `Spread S ${bestAsk - bestBid}` : 'One-sided book'}</span>
            </div>
            {bidRows.map((l) => (
              <button
                type="button"
                key={`b${l.yes_price}`}
                className="book-row bid"
                style={{ '--depth': `${Math.round((l.depth / deepest) * 100)}%` } as CSSProperties}
                aria-label={`Sell ${word} at S ${l.yes_price}, ${l.qty} shares`}
                disabled={market.status !== 'OPEN'}
                onClick={() => onPick({ side: 'SELL', outcome, type: 'limit', price: l.yes_price })}
              >
                <span className="price">S {l.yes_price}</span>
                <span>{number(l.qty)}</span>
                <span className="muted">{sedi(l.qty * l.yes_price)}</span>
              </button>
            ))}
          </div>
          <p className="hint">
            Tap a price to fill the order panel.
            {bestBid != null && ` ${other} prices mirror these: a ${outcome === 'YES' ? 'Yes' : 'No'} bid at S ${bestBid} is a ${other} offer at S ${V - bestBid}.`}
          </p>
        </>
      )}
    </section>
  )
}

export function RecentTrades({ market }: { market: Market }) {
  const trades = useTrades(market.id)
  const items = trades.data?.items ?? []
  return (
    <section className="panel trades" aria-labelledby="trades-h">
      <h2 id="trades-h">Recent trades</h2>
      {trades.error ? (
        <Notice error={trades.error} />
      ) : items.length ? (
        <ol>
          {items.map((t) => {
            const s = tradeSide(t, market.redemption_units)
            return (
              <li key={`${t.execution_seq}-${t.fill_index}`}>
                <SidePill outcome={s.outcome} />
                <span className="grow">
                  {number(t.qty)} @ S {s.price}
                </span>
                <span className="muted">{clock(t.created_at)}</span>
              </li>
            )
          })}
        </ol>
      ) : (
        <p className="muted">{trades.isLoading ? 'Loading…' : 'No trades yet.'}</p>
      )}
    </section>
  )
}

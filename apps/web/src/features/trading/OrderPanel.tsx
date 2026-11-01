import { useCallback, useEffect, useMemo, useState } from 'react'
import { Link } from '@tanstack/react-router'
import { isApiError } from '../../api'
import { number, sedi } from '../../format'
import { useMe } from '../../session'
import { LockIcon } from '../../ui/icons'
import { Notice } from '../../ui/kit'
import { useToast } from '../../ui/toast'
import { useSummary } from '../portfolio/api'
import { isTradable, type Book, type Market } from '../markets/api'
import type { Order, OrderIntent, OrderType, Outcome, Position, Side, Tif } from './api'
import { best, estimateBuy, estimateSell, ladder } from './quote'
import { describeOrder, UnresolvedIntentError, useOrderSubmission } from './submit'

export type Prefill = { side: Side; outcome: Outcome; type: OrderType; price?: number; nonce: number }

type Props = { market: Market; book: Book | undefined; positions: Position[]; prefill: Prefill | null }

const LOCKS: Record<string, [string, string]> = {
  SUSPENDED: ['Trading paused', 'You can still cancel open orders.'],
  CLOSED: ['Trading closed', 'Payouts go out once the result is final.'],
  RESOLUTION_PENDING: ['Trading closed', 'Payouts go out once the result is final.'],
  DISPUTED: ['Result disputed', 'Payouts go out once the result is final.'],
  RESOLVED: ['Result final', 'Payouts are on their way.'],
  SETTLING: ['Paying out', 'Winning shares are being paid.'],
  SETTLED: ['This market is settled', 'Payouts are in your balance.'],
  VOIDED: ['Market voided', 'Holdings were refunded.'],
}

const clamp = (value: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, value))

function Stepper({ label, value, onChange, min, max, step = 1, prefix }: { label: string; value: number; onChange: (v: number) => void; min: number; max: number; step?: number; prefix?: string }) {
  const id = `stepper-${label.toLowerCase().replace(/\s+/g, '-')}`
  return (
    <div className="stepper-row">
      <label htmlFor={id}>{label}</label>
      <div className="stepper">
        <button type="button" aria-label={`Decrease ${label.toLowerCase()}`} onClick={() => onChange(clamp(value - step, min, max))}>
          −
        </button>
        {prefix && <span className="prefix">{prefix}</span>}
        <input id={id} type="number" inputMode="numeric" min={min} max={max} step={step} value={value} onChange={(e) => onChange(clamp(Math.round(Number(e.target.value) || 0), 0, max))} />
        <button type="button" aria-label={`Increase ${label.toLowerCase()}`} onClick={() => onChange(clamp(value + step, min, max))}>
          +
        </button>
      </div>
    </div>
  )
}

export function OrderPanel({ market, book, positions, prefill }: Props) {
  const { user, signedIn } = useMe()
  const summary = useSummary(signedIn)
  const toast = useToast()
  const fee = market.fee_units
  const band = market.price_band
  const V = market.redemption_units

  const [side, setSide] = useState<Side>('BUY')
  const [outcome, setOutcome] = useState<Outcome>(() => (new URLSearchParams(window.location.search).get('outcome') === 'NO' ? 'NO' : 'YES'))
  const [type, setType] = useState<OrderType>('market')
  const [spend, setSpend] = useState(100)
  const [qty, setQty] = useState(10)
  const [limit, setLimit] = useState(band.min)
  const [tif, setTif] = useState<Tif>('GTC')

  const quoteLadder = useMemo(() => ladder(book, outcome, V), [book, outcome, V])
  const yesLadder = useMemo(() => ladder(book, 'YES', V), [book, V])
  const noLadder = useMemo(() => ladder(book, 'NO', V), [book, V])

  useEffect(() => {
    if (!prefill) return
    setSide(prefill.side)
    setOutcome(prefill.outcome)
    setType(prefill.type)
    if (prefill.price != null) setLimit(prefill.price)
  }, [prefill])

  const onSettled = useCallback((order: Order) => toast(describeOrder(order)), [toast])
  const submission = useOrderSubmission(market.id, user?.id, onSettled)

  useEffect(() => {
    const intent = submission.unresolved
    if (!intent) return
    setType(intent.type)
    setSide(intent.side)
    setOutcome(intent.outcome)
    if (intent.type === 'market' && intent.side === 'BUY') setSpend(intent.spend)
    else setQty(intent.qty)
    if (intent.type === 'limit') {
      setLimit(intent.price)
      setTif(intent.tif)
    }
  }, [submission.unresolved])

  const tradable = isTradable(market)
  if (!tradable) {
    const [title, body] = LOCKS[market.status] ?? ['Trading unavailable', market.status_note || 'This market is not open for trading.']
    return (
      <section className="panel order-panel locked" aria-label="Place an order">
        <LockIcon size={28} />
        <strong>{title}</strong>
        <span>{market.status_note || body}</span>
      </section>
    )
  }

  const held = positions.find((p) => p.market.id === market.id && p.outcome === outcome)
  const free = held?.qty_free ?? 0
  const inOrders = held?.qty_in_orders ?? 0
  const available = summary.data?.available ?? null
  const isBuy = side === 'BUY'
  const isMarket = type === 'market'
  const sideLabel = outcome === 'YES' ? 'Yes' : 'No'
  const quote = (l: typeof yesLadder) => best(isBuy ? l.asks : l.bids)
  const bestAsk = best(quoteLadder.asks)
  const bestBid = best(quoteLadder.bids)

  let lines: [string, string][] = []
  let bigLabel = 'To win'
  let big = 0
  let cost = 0
  let rest = ''
  let warn = ''
  let blocked = false
  let intent: OrderIntent

  if (isBuy && isMarket) {
    const est = estimateBuy(quoteLadder.asks, spend, fee)
    cost = spend
    lines = [
      ['Shares', est.shares ? `about ${number(est.shares)}` : '—'],
      ['Avg price', est.shares ? `S ${(est.cost / est.shares).toFixed(1)}${est.worst != null && bestAsk != null && est.worst > bestAsk ? ` · up to S ${est.worst}` : ''}` : '—'],
    ]
    big = est.shares * V
    if (bestAsk == null) [warn, blocked] = ['Nobody is selling right now. Try a limit order.', true]
    else if (est.shares < 1) [warn, blocked] = [`Not enough for one share at S ${bestAsk}.`, true]
    else if (est.exhausted) warn = 'The book runs out before your amount is spent; the rest stays in your balance.'
    else if (spend < 10) warn = `Heads up: the S ${fee} fee is a big chunk of a small bet.`
    intent = { type: 'market', outcome, side: 'BUY', spend }
  } else if (isBuy) {
    const principal = qty * limit
    cost = principal + fee
    lines = [
      ['Shares × price', `${number(qty)} × S ${limit}`],
      ['Cost', sedi(principal)],
    ]
    big = qty * V
    if (bestAsk != null && limit < bestAsk) {
      rest = tif === 'GTC' ? `Below the best offer (S ${bestAsk}), so it waits on the book until someone sells to you.` : `Below the best offer (S ${bestAsk}). With “cancel the rest” it would cancel right away.`
    }
    if (principal < 2) [warn, blocked] = ['The smallest order is S 2.', true]
    intent = { type: 'limit', outcome, side: 'BUY', price: limit, qty, tif }
  } else {
    const est = isMarket ? estimateSell(quoteLadder.bids, qty) : { proceeds: qty * limit, sold: qty, worst: limit }
    lines = [
      ['Shares', number(qty)],
      [isMarket ? 'Avg price' : 'Price', isMarket ? (est.sold ? `S ${(est.proceeds / est.sold).toFixed(1)}` : '—') : `S ${limit}`],
    ]
    bigLabel = 'You receive'
    big = Math.max(0, est.proceeds - fee)
    if (!isMarket && bestBid != null && limit > bestBid) rest = `Above the best bid (S ${bestBid}), so it waits on the book until someone buys from you.`
    if (free === 0) [warn, blocked] = [`You don’t have any ${sideLabel} shares to sell.`, true]
    else if (qty > free) [warn, blocked] = [`You have ${free} ${sideLabel} shares free.${inOrders ? ` The other ${inOrders} are in a sell order.` : ''}`, true]
    else if (isMarket && bestBid == null) [warn, blocked] = ['Nobody is buying right now. Try a limit order.', true]
    intent = isMarket ? { type: 'market', outcome, side: 'SELL', qty } : { type: 'limit', outcome, side: 'SELL', price: limit, qty, tif }
  }

  if (!blocked && isBuy && available != null && cost > available) [warn, blocked] = [`That’s more than your ${sedi(available)} balance.`, true]
  if (qty > market.max_order_qty && !(isBuy && isMarket)) [warn, blocked] = [`The most you can trade in one order is ${number(market.max_order_qty)} shares.`, true]

  const busy = submission.submitting || submission.awaiting
  const ctaLabel = submission.awaiting
    ? 'Waiting for the result…'
    : submission.submitting
      ? 'Sending…'
      : isBuy
        ? `Buy ${sideLabel} · ${sedi(isMarket ? spend : cost)}`
        : `Sell ${number(qty)} ${sideLabel} · get ${sedi(big)}`

  const setChipSpend = (n: number) => setSpend(clamp(n, 0, available ?? n))

  return (
    <section className="panel order-panel" aria-labelledby="panel-h">
      <h2 id="panel-h" className="sr-only">
        Place an order
      </h2>
      <div className="order-head">
        <div role="group" aria-label="Buy or sell" className="line-tabs">
          <button type="button" aria-pressed={isBuy} onClick={() => setSide('BUY')}>
            Buy
          </button>
          <button
            type="button"
            aria-pressed={!isBuy}
            onClick={() => {
              setSide('SELL')
              if (free) setQty(Math.min(qty, free))
            }}
          >
            Sell
          </button>
        </div>
        <label className="compact-select">
          <span className="sr-only">Order type</span>
          <select value={type} onChange={(e) => setType(e.target.value as OrderType)}>
            <option value="market">Market</option>
            <option value="limit">Limit</option>
          </select>
        </label>
      </div>

      <div role="group" aria-label="Outcome" className="outcome-pair">
        {(['YES', 'NO'] as const).map((o) => {
          const q = quote(o === 'YES' ? yesLadder : noLadder)
          return (
            <button
              type="button"
              key={o}
              aria-pressed={outcome === o}
              className={`outcome ${o === 'YES' ? 'yes' : 'no'}`}
              onClick={() => {
                setOutcome(o)
                const next = best(isBuy ? ladder(book, o, V).asks : ladder(book, o, V).bids)
                if (next != null) setLimit(next)
              }}
            >
              {o === 'YES' ? 'Yes' : 'No'} {q == null ? '—' : `S ${q}`}
            </button>
          )
        })}
      </div>

      {isBuy && isMarket ? (
        <div className="amount-box">
          <label htmlFor="order-amount">Amount</label>
          <div className="amount-input">
            <span>S</span>
            <input id="order-amount" type="number" inputMode="numeric" min={1} value={spend} onChange={(e) => setSpend(Math.max(0, Math.round(Number(e.target.value) || 0)))} />
          </div>
          <div className="chips-row">
            <button type="button" onClick={() => setChipSpend(spend + 10)}>
              +10
            </button>
            <button type="button" onClick={() => setChipSpend(spend + 50)}>
              +50
            </button>
            <button type="button" onClick={() => setChipSpend(spend + 100)}>
              +100
            </button>
            <button type="button" disabled={available == null} onClick={() => available != null && setSpend(available)}>
              Max
            </button>
          </div>
        </div>
      ) : (
        <div className="stepper-group">
          {!isMarket && <Stepper label="Limit price" value={limit} onChange={setLimit} min={band.min} max={band.max} step={band.tick} prefix="S" />}
          <Stepper label="Shares" value={qty} onChange={setQty} min={1} max={market.max_order_qty} />
          {!isBuy && (
            <p className="hint right">
              You have {free} {sideLabel} shares free ·{' '}
              <button type="button" className="link-button" disabled={!free} onClick={() => setQty(free)}>
                Sell all
              </button>
            </p>
          )}
          {!isMarket && (
            <label className="inline-select">
              If not filled
              <select value={tif} onChange={(e) => setTif(e.target.value as Tif)}>
                <option value="GTC">Keep it open</option>
                <option value="IOC">Cancel the rest</option>
              </select>
            </label>
          )}
        </div>
      )}

      <dl className="order-lines">
        {lines.map(([label, value]) => (
          <div key={label}>
            <dt>{label}</dt>
            <dd>{value}</dd>
          </div>
        ))}
        <div>
          <dt>Fee</dt>
          <dd>{sedi(fee)}</dd>
        </div>
        <div className="big">
          <dt>{bigLabel}</dt>
          <dd className={isBuy ? 'up' : ''}>{sedi(big)}</dd>
        </div>
      </dl>
      {isMarket && <p className="hint">Estimated from the current book. The final price is set when your order matches.</p>}
      {rest && <p className="rest-note">{rest}</p>}
      {warn && (
        <p className="warn" role="status">
          {warn}
        </p>
      )}
      {submission.unresolved && (
        <div className="notice" role="alert">
          {submission.error instanceof UnresolvedIntentError
            ? submission.error.message
            : 'Your last order may have gone through. Retry with the same details to see what happened, or check your open orders.'}
          <button type="button" className="link-button" onClick={submission.discard}>
            Start a new order
          </button>
        </div>
      )}
      {submission.error && !(submission.error instanceof UnresolvedIntentError) && <Notice error={submission.error} />}
      {isApiError(submission.trackError) && <Notice>We couldn’t refresh this order. Check your open orders.</Notice>}
      {signedIn ? (
        <button type="button" className={`cta ${outcome === 'YES' ? 'yes' : 'no'}`} disabled={blocked || busy} onClick={() => submission.submit(intent)}>
          {ctaLabel}
        </button>
      ) : (
        <Link to="/login" className="cta lime">
          Log in to trade
        </Link>
      )}
    </section>
  )
}

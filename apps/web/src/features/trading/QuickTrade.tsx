import { useCallback, useEffect, useRef, useState } from 'react'
import { Link } from '@tanstack/react-router'
import { number, sedi } from '../../format'
import { useMe } from '../../session'
import { CloseIcon } from '../../ui/icons'
import { Loading, Notice } from '../../ui/kit'
import { useToast } from '../../ui/toast'
import { useSummary } from '../portfolio/api'
import { isTradable, useBook, useMarket, type MarketCard } from '../markets/api'
import type { Order, Outcome } from './api'
import { best, estimateBuy, ladder } from './quote'
import { describeOrder, UnresolvedIntentError, useOrderSubmission } from './submit'

type Props = { card: MarketCard; outcome: Outcome; onClose: () => void }

export function QuickTrade({ card, outcome: initial, onClose }: Props) {
  const { user, signedIn } = useMe()
  const market = useMarket(card.slug)
  const book = useBook(card.id)
  const summary = useSummary(signedIn)
  const toast = useToast()
  const [outcome, setOutcome] = useState<Outcome>(initial)
  const [amount, setAmount] = useState(100)
  const dialog = useRef<HTMLDivElement>(null)

  const onSettled = useCallback(
    (order: Order) => {
      toast(describeOrder(order))
      onClose()
    },
    [toast, onClose],
  )
  const submission = useOrderSubmission(card.id, user?.id, onSettled)

  useEffect(() => {
    const previous = document.activeElement as HTMLElement | null
    dialog.current?.querySelector<HTMLElement>('button, a, input')?.focus()
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose()
    }
    dialog.current?.addEventListener('keydown', onKey)
    const node = dialog.current
    return () => {
      node?.removeEventListener('keydown', onKey)
      previous?.focus()
    }
  }, [onClose])

  useEffect(() => {
    const intent = submission.unresolved
    if (intent?.type === 'market' && intent.side === 'BUY') {
      setOutcome(intent.outcome)
      setAmount(intent.spend)
    }
  }, [submission.unresolved])

  const m = market.data
  const V = card.redemption_units
  const asks = ladder(book.data, outcome, V).asks
  const fee = m?.fee_units ?? 0
  const est = estimateBuy(asks, amount, fee)
  const price = best(asks)
  const available = summary.data?.available ?? null

  let warn = ''
  let blocked = !m || !isTradable(m)
  if (m && !isTradable(m)) warn = m.status_note || 'Trading is closed on this market.'
  else if (book.isError) [warn, blocked] = ['Prices are unavailable right now. Try again shortly.', true]
  else if (price == null) [warn, blocked] = ['Nobody is selling this side right now.', true]
  else if (est.shares < 1) [warn, blocked] = [`Not enough for one share at S ${price}.`, true]
  else if (signedIn && available != null && amount > available) [warn, blocked] = [`That’s more than your ${sedi(available)} balance.`, true]
  else if (amount < 10) warn = `Heads up: the S ${fee} fee is a big chunk of a small bet.`

  const bump = (n: number) => setAmount(Math.max(0, n))
  const sideLabel = outcome === 'YES' ? 'Yes' : 'No'

  return (
    <div
      className="scrim"
      onMouseDown={(e) => {
        if (e.target === e.currentTarget) onClose()
      }}
    >
      <div ref={dialog} role="dialog" aria-modal="true" aria-labelledby="qt-title" className="dialog">
        <div className="dialog-head">
          <h2 id="qt-title">{card.question}</h2>
          <button type="button" className="icon-button round" aria-label="Close" onClick={onClose}>
            <CloseIcon size={14} />
          </button>
        </div>
        {market.isLoading ? (
          <Loading />
        ) : market.error ? (
          <Notice error={market.error} />
        ) : (
          <>
            <div role="group" aria-label="Pick a side" className="outcome-pair">
              {(['YES', 'NO'] as const).map((o) => {
                const q = best(ladder(book.data, o, V).asks)
                return (
                  <button type="button" key={o} aria-pressed={outcome === o} className={`outcome ${o === 'YES' ? 'yes' : 'no'}`} onClick={() => setOutcome(o)}>
                    {o === 'YES' ? 'Yes' : 'No'} {q == null ? '—' : `S ${q}`}
                  </button>
                )
              })}
            </div>
            <div className="amount-box">
              <label htmlFor="qt-amount">Amount</label>
              <div className="amount-input">
                <span>S</span>
                <input id="qt-amount" type="number" inputMode="numeric" min={1} value={amount} onChange={(e) => setAmount(Math.max(0, Math.round(Number(e.target.value) || 0)))} />
              </div>
              <div className="chips-row">
                <button type="button" onClick={() => bump(amount + 10)}>
                  +10
                </button>
                <button type="button" onClick={() => bump(amount + 50)}>
                  +50
                </button>
                <button type="button" onClick={() => bump(amount + 100)}>
                  +100
                </button>
                <button type="button" disabled={available == null} onClick={() => available != null && setAmount(available)}>
                  Max
                </button>
              </div>
            </div>
            <dl className="order-lines">
              <div>
                <dt>Shares</dt>
                <dd>{est.shares ? `about ${number(est.shares)} × S ${price}` : '—'}</dd>
              </div>
              <div>
                <dt>Fee</dt>
                <dd>{sedi(fee)}</dd>
              </div>
              <div className="big">
                <dt>To win</dt>
                <dd className="up">{sedi(est.shares * V)}</dd>
              </div>
            </dl>
            {warn && (
              <p className="warn" role="status">
                {warn}
              </p>
            )}
            {submission.unresolved && (
              <div className="notice" role="alert">
                {submission.error instanceof UnresolvedIntentError ? submission.error.message : 'Your last order may have gone through. Retry with the same details, or check your open orders.'}
                <button type="button" className="link-button" onClick={submission.discard}>
                  Start a new order
                </button>
              </div>
            )}
            {submission.error && !(submission.error instanceof UnresolvedIntentError) && <Notice error={submission.error} />}
            {signedIn ? (
              <button
                type="button"
                className={`cta ${outcome === 'YES' ? 'yes' : 'no'}`}
                disabled={blocked || submission.submitting || submission.awaiting}
                onClick={() => submission.submit({ type: 'market', outcome, side: 'BUY', spend: amount })}
              >
                {submission.awaiting ? 'Waiting for the result…' : submission.submitting ? 'Sending…' : `Buy ${sideLabel} · ${sedi(amount)}`}
              </button>
            ) : (
              <Link to="/signup" className="cta lime">
                Sign up to play · get S 1,000
              </Link>
            )}
          </>
        )}
      </div>
    </div>
  )
}

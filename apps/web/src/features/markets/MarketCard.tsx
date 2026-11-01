import { Link } from '@tanstack/react-router'
import { compactSedi, timeLeft, weekdayTime } from '../../format'
import { CategoryIcon } from '../../ui/icons'
import { Gauge } from '../../ui/kit'
import type { Outcome } from '../trading/api'
import { isTradable, type MarketCard as Card } from './api'

const LOCK_NOTE: Record<string, string> = {
  SUSPENDED: 'Paused',
  CLOSED: 'Trading closed',
  RESOLUTION_PENDING: 'Settling',
  DISPUTED: 'Result disputed',
  RESOLVED: 'Result final',
  SETTLING: 'Paying out',
  SETTLED: 'Settled',
  VOIDED: 'Voided',
}

export function closesLabel(card: Card, now = Date.now()) {
  if (!card.closes_at) return ''
  if (card.closing_soon) return `Ends in ${timeLeft(card.closes_at, now).replace(' left', '')}`
  if (new Date(card.closes_at).getTime() < now) return 'Closed'
  return weekdayTime(card.closes_at)
}

export function MarketCard({ card, onTrade }: { card: Card; onTrade: (card: Card, outcome: Outcome) => void }) {
  const tradable = isTradable(card)
  const resolving = ['RESOLUTION_PENDING', 'DISPUTED', 'CLOSED'].includes(card.status)
  return (
    <article className="market-card">
      <div className="market-card-head">
        <CategoryIcon icon={card.category.icon} size="sm" />
        <Link to="/markets/$selector" params={{ selector: card.slug }} className="market-card-q">
          {card.question}
        </Link>
        <Gauge pct={card.chance_pct} muted={!tradable} />
      </div>
      {tradable ? (
        <div className="trade-pair">
          <button type="button" className="soft yes" aria-label={card.yes_ask == null ? 'Buy yes' : `Buy yes at S ${card.yes_ask}`} onClick={() => onTrade(card, 'YES')}>
            Yes {card.yes_ask ?? '—'}
          </button>
          <button type="button" className="soft no" aria-label={card.no_ask == null ? 'Buy no' : `Buy no at S ${card.no_ask}`} onClick={() => onTrade(card, 'NO')}>
            No {card.no_ask ?? '—'}
          </button>
        </div>
      ) : (
        <div className={`lock-note ${resolving ? 'resolving' : ''}`}>{card.status_note || LOCK_NOTE[card.status] || card.status}</div>
      )}
      <div className="market-card-foot">
        <span>{card.volume_units == null ? 'No volume yet' : `${compactSedi(card.volume_units)} vol`}</span>
        <span className={card.closing_soon ? 'closing' : ''}>{closesLabel(card)}</span>
      </div>
    </article>
  )
}

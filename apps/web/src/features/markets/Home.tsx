import { useCallback, useState } from 'react'
import { Link, useNavigate, useSearch } from '@tanstack/react-router'
import { useInfiniteQuery, useQuery } from '@tanstack/react-query'
import { get, type Page } from '../../api'
import { compactSedi, ordinal, sedi, signedSedi, timeLeft, weekdayTime } from '../../format'
import { useLiveMarkets } from '../../live'
import { useMe } from '../../session'
import { PlayerLayout } from '../../shell'
import { AreaChart } from '../../ui/chart'
import { CategoryIcon } from '../../ui/icons'
import { Countdown, Empty, Loading, Notice, useNow } from '../../ui/kit'
import { useSummary } from '../portfolio/api'
import { QuickTrade } from '../trading/QuickTrade'
import type { Outcome } from '../trading/api'
import { MarketCard } from './MarketCard'
import { isTradable, marketsPath, searchPath, useCategories, useFeatured, useHistory, useLeaderStrip, useSeason, type Filter, type MarketCard as Card } from './api'

type View = { filter: Filter; category: string; label: string }

const TRENDING: View = { filter: 'trending', category: '', label: 'Trending' }
const ENDING: View = { filter: 'ending_soon', category: '', label: 'Ending soon' }

function CategoryBar({ view, onPick }: { view: View; onPick: (v: View) => void }) {
  const categories = useCategories()
  const season = useSeason()
  const now = useNow(60_000)
  const views: View[] = [TRENDING, ENDING, ...(categories.data ?? []).map((c) => ({ filter: 'new' as const, category: c.id, label: c.name }))]
  return (
    <div className="header-row sub">
      <div role="group" aria-label="Categories" className="category-chips">
        {views.map((v) => (
          <button type="button" key={v.label} aria-pressed={v.label === view.label} onClick={() => onPick(v)}>
            {v.label}
          </button>
        ))}
      </div>
      {season.data && (
        <span className="season-pill">
          <span className="dot" aria-hidden="true" />
          Season {ordinal(season.data.ordinal)} · {timeLeft(season.data.ends_at, now)}
        </span>
      )}
    </div>
  )
}

function Hero({ card, onTrade }: { card: Card; onTrade: (card: Card, outcome: Outcome) => void }) {
  const history = useHistory(card.id, '1W')
  const closes = history.data?.items.map((c) => c.close) ?? []
  const change = card.change_24h
  return (
    <article className="panel hero" aria-labelledby="hero-q">
      <div className="hero-head">
        <CategoryIcon icon={card.category.icon} size="md" />
        <div>
          <span className="eyebrow">
            {card.category.name} · {weekdayTime(card.closes_at)}
          </span>
          <h1 id="hero-q">
            <Link to="/markets/$selector" params={{ selector: card.slug }}>
              {card.question}
            </Link>
          </h1>
        </div>
      </div>
      <div className="hero-chart">
        <div>
          <div className="big-chance">
            <strong className={card.chance_pct != null && card.chance_pct < 50 ? 'down' : 'up'}>{card.chance_pct == null ? '—' : `${Math.round(card.chance_pct)}%`}</strong>
            {change != null && change !== 0 && <span className={change > 0 ? 'up' : 'down'}>{`${change > 0 ? '▲' : '▼'} ${Math.abs(Math.round(change))}`}</span>}
          </div>
          <small className="muted">{card.chance_pct == null ? 'no trades yet' : 'chance'}</small>
        </div>
        {closes.length > 1 ? (
          <AreaChart values={closes} width={600} height={140} min={Math.max(0, Math.min(...closes) - 4)} max={Math.min(card.redemption_units, Math.max(...closes) + 4)} guides={[0.5]} label={`Yes price over the last week, from S ${closes[0]} to S ${closes[closes.length - 1]}`} className="hero-spark" />
        ) : (
          <p className="muted chart-empty">{history.isLoading ? 'Loading price history…' : 'Not enough trades yet for a chart.'}</p>
        )}
      </div>
      {isTradable(card) ? (
        <div className="trade-pair big">
          <button type="button" className="solid yes" onClick={() => onTrade(card, 'YES')}>
            Yes · {sedi(card.yes_ask)}
          </button>
          <button type="button" className="solid no" onClick={() => onTrade(card, 'NO')}>
            No · {sedi(card.no_ask)}
          </button>
        </div>
      ) : (
        <div className="lock-note">{card.status_note || 'Trading is closed on this market.'}</div>
      )}
      <div className="meta-row">
        <span>{card.volume_units == null ? 'No volume yet' : `${compactSedi(card.volume_units)} volume`}</span>
        <span>Pays {sedi(card.redemption_units)} per share</span>
      </div>
    </article>
  )
}

function SeasonCard() {
  const season = useSeason()
  const { signedIn } = useMe()
  const summary = useSummary(signedIn)
  const s = season.data
  return (
    <aside className="season-card" aria-label="Season">
      <span className="eyebrow">{s ? `Season ${ordinal(s.ordinal)}` : 'Between seasons'}</span>
      <p className="season-pitch">
        {s ? `Everyone starts level. ${s.days_total ? `${Math.round(s.days_total / 7)} weeks` : 'One season'}. Top of the board wins.` : 'The next season opens soon. Everyone starts level.'}
      </p>
      {s && <Countdown until={s.ends_at} className="dark" />}
      {signedIn ? (
        <Link to="/leaderboard" className="season-me">
          <span>
            {summary.data?.rank ? `You’re #${summary.data.rank.position}` : 'Not ranked yet'}
            {summary.data?.season_pnl != null && ` · ${signedSedi(summary.data.season_pnl)}`}
          </span>
          <span>Board →</span>
        </Link>
      ) : (
        <Link to="/signup" className="season-cta">
          Claim your free sedis
        </Link>
      )}
    </aside>
  )
}

function LeaderStrip() {
  const strip = useLeaderStrip()
  const rows = strip.data?.items.slice(0, 5) ?? []
  if (!rows.length) return null
  return (
    <section className="panel leader-strip" aria-labelledby="lb-h">
      <h2 id="lb-h">Top this season</h2>
      <ol>
        {rows.map((r) => (
          <li key={r.account_id}>
            <span className="rank-dot" style={{ background: r.avatar_color }}>
              {r.rank}
            </span>
            <Link to="/users/$username" params={{ username: r.username }}>
              {r.username}
            </Link>
            <span className={r.profit >= 0 ? 'up' : 'down'}>{signedSedi(r.profit).replace('S ', '')}</span>
          </li>
        ))}
      </ol>
      <Link to="/leaderboard" className="muted-link">
        Full board →
      </Link>
    </section>
  )
}

export function Home() {
  useLiveMarkets()
  const { q } = useSearch({ from: '/' })
  const term = q?.trim() ?? ''
  const navigate = useNavigate()
  const [view, setView] = useState<View>(TRENDING)
  const [trade, setTrade] = useState<{ card: Card; outcome: Outcome } | null>(null)
  const featured = useFeatured()
  const searching = term.length >= 2

  const markets = useInfiniteQuery({
    queryKey: ['markets', view.filter, view.category],
    initialPageParam: '',
    queryFn: ({ pageParam }) => get<Page<Card>>(marketsPath(view.filter, view.category, pageParam)),
    getNextPageParam: (last) => last.next_cursor ?? undefined,
    enabled: !searching,
  })
  const results = useQuery({ queryKey: ['markets', 'search', term], queryFn: () => get<Card[]>(searchPath(term)), enabled: searching })

  const openTrade = useCallback((card: Card, outcome: Outcome) => setTrade({ card, outcome }), [])
  const closeTrade = useCallback(() => setTrade(null), [])
  const pick = (v: View) => {
    setView(v)
    if (term) void navigate({ to: '/', search: {} })
  }

  const hero = featured.data
  const list = searching ? (results.data ?? []) : (markets.data?.pages.flatMap((p) => p.items) ?? []).filter((m) => m.id !== hero?.id || view !== TRENDING)
  const loading = searching ? results.isLoading : markets.isLoading
  const error = searching ? results.error : markets.error

  return (
    <PlayerLayout header={<CategoryBar view={view} onPick={pick} />}>
      <main className="container home">
        {!searching && (
          <section className="hero-row">
            {hero ? (
              <Hero card={hero} onTrade={openTrade} />
            ) : (
              <article className="panel hero intro">
                <h1>Make your call.</h1>
                <p className="muted">Pick a side on football, music, tech and whatever the timeline is arguing about. No real money.</p>
                <Notice error={featured.error} />
              </article>
            )}
            <SeasonCard />
          </section>
        )}
        <section aria-labelledby="grid-h" className="stack">
          <div className="section-head">
            <h2 id="grid-h">{searching ? `Results for “${term}”` : view === TRENDING ? 'Trending now' : view.label}</h2>
            {searching && (
              <Link to="/" search={{}} className="muted-link">
                Clear search
              </Link>
            )}
          </div>
          {term.length === 1 && <p className="muted">Type at least two characters to search.</p>}
          {loading ? (
            <Loading label="Loading markets…" />
          ) : error ? (
            <Notice error={error} />
          ) : list.length ? (
            <div className="market-grid">
              {list.map((m) => (
                <MarketCard key={m.id} card={m} onTrade={openTrade} />
              ))}
            </div>
          ) : (
            <Empty title={searching ? 'No markets match that' : 'Nothing here yet'}>{searching ? 'Try a team, an artist or a topic.' : 'New markets open every week.'}</Empty>
          )}
          {!searching && markets.hasNextPage && (
            <button type="button" className="button ghost center" disabled={markets.isFetchingNextPage} onClick={() => void markets.fetchNextPage()}>
              {markets.isFetchingNextPage ? 'Loading…' : 'Show more'}
            </button>
          )}
        </section>
        <LeaderStrip />
      </main>
      {trade && <QuickTrade card={trade.card} outcome={trade.outcome} onClose={closeTrade} />}
    </PlayerLayout>
  )
}

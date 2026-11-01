import { useCallback, useState } from 'react'
import { Link, useParams } from '@tanstack/react-router'
import { isApiError } from '../../api'
import { compactSedi, dateTime, ordinal, sedi, day } from '../../format'
import { useLiveMarkets } from '../../live'
import { useMe } from '../../session'
import { PlayerLayout } from '../../shell'
import { CategoryIcon, ShareIcon } from '../../ui/icons'
import { Empty, Loading, Notice } from '../../ui/kit'
import { useToast } from '../../ui/toast'
import { usePositions } from '../trading/api'
import { MarketOrders, YourPosition } from '../trading/MarketPrivate'
import { OrderPanel, type Prefill } from '../trading/OrderPanel'
import { useBook, useMarket, type Market } from './api'
import { OrderBook, RecentTrades } from './OrderBook'
import { PriceChart } from './PriceChart'
import { Evidence, StatusBanner, useResolutionBanner } from './Resolution'

function Rules({ market }: { market: Market }) {
  const band = market.price_band
  const facts: [string, string][] = [
    ['Source', market.resolution_source?.name ?? '—'],
    ['Trading closes', dateTime(market.closes_at)],
    ['Result expected', dateTime(market.resolve_by)],
    ['Winning share pays', sedi(market.redemption_units)],
    ['Price range', `S ${band.min} – S ${band.max}, steps of S ${band.tick}`],
    ['Fee', `${sedi(market.fee_units)} per order, once`],
  ]
  if (market.season) facts.push(['Season', `${ordinal(market.season.ordinal)} · ends ${day(market.season.ends_at)}`])
  return (
    <section id="rules" className="panel rules" aria-labelledby="rules-h">
      <h2 id="rules-h">Rules</h2>
      <div className="rules-text">
        <p>
          Resolves <strong className="up">Yes</strong> if {market.rules.yes_if}
        </p>
        <p>
          Resolves <strong className="down">No</strong> if {market.rules.no_if}
        </p>
        {market.rules.edge_cases && <p>{market.rules.edge_cases}</p>}
      </div>
      <dl className="facts">
        {facts.map(([k, v]) => (
          <div key={k}>
            <dt>{k}</dt>
            <dd>
              {k === 'Source' && market.resolution_source?.url ? (
                <a href={market.resolution_source.url} target="_blank" rel="noreferrer">
                  {v}
                </a>
              ) : (
                v
              )}
            </dd>
          </div>
        ))}
      </dl>
    </section>
  )
}

function ShareButton({ question }: { question: string }) {
  const toast = useToast()
  const share = async () => {
    const url = window.location.href.split('?')[0]
    try {
      if (navigator.share) await navigator.share({ title: question, url })
      else {
        await navigator.clipboard.writeText(url)
        toast({ title: 'Link copied' })
      }
    } catch (error) {
      if (!(error instanceof DOMException && error.name === 'AbortError')) toast({ title: 'Couldn’t share', body: 'Copy the address bar instead.' })
    }
  }
  return (
    <button type="button" className="icon-button boxed" aria-label="Share market" onClick={() => void share()}>
      <ShareIcon />
    </button>
  )
}

function Detail({ market }: { market: Market }) {
  const { signedIn } = useMe()
  const book = useBook(market.id)
  const positions = usePositions(signedIn)
  const banner = useResolutionBanner(market)
  const [prefill, setPrefill] = useState<Prefill | null>(null)
  const [disputing, setDisputing] = useState(false)
  const pick = useCallback((p: Omit<Prefill, 'nonce'>) => {
    setPrefill({ ...p, nonce: Date.now() })
    document.getElementById('panel-h')?.closest('section')?.scrollIntoView({ behavior: 'smooth', block: 'nearest' })
  }, [])
  const openDispute = () => {
    setDisputing(true)
    requestAnimationFrame(() => document.getElementById('evidence')?.scrollIntoView({ behavior: 'smooth' }))
  }
  return (
    <main className="container detail">
      <nav aria-label="Breadcrumb" className="crumbs">
        <Link to="/">Markets</Link>
        <span aria-hidden="true">/</span>
        <span>{market.category.name ?? 'Market'}</span>
      </nav>
      <div className="detail-grid">
        <div className="detail-main">
          <div className="detail-head">
            <CategoryIcon icon={market.category.icon} size="lg" />
            <div className="grow">
              <h1>{market.question}</h1>
              <div className="meta-row">
                <span>{market.volume_units == null ? 'No volume yet' : `${compactSedi(market.volume_units)} volume`}</span>
                <span>Closes {dateTime(market.closes_at)}</span>
                <span>Pays {sedi(market.redemption_units)} per share</span>
              </div>
            </div>
            <ShareButton question={market.question} />
          </div>
          {banner && <StatusBanner banner={banner} onDispute={openDispute} />}
          <PriceChart market={market} />
          <div className="split">
            <OrderBook market={market} onPick={pick} />
            <RecentTrades market={market} />
          </div>
          <Evidence market={market} signedIn={signedIn} disputeOpen={disputing} onCloseDispute={() => setDisputing(false)} />
          <Rules market={market} />
        </div>
        <aside className="detail-side" aria-label="Trade">
          <OrderPanel market={market} book={book.data} positions={positions.data?.items ?? []} prefill={prefill} />
          {signedIn && (
            <>
              <YourPosition marketId={market.id} positions={positions.data?.items ?? []} />
              <MarketOrders marketId={market.id} />
            </>
          )}
        </aside>
      </div>
    </main>
  )
}

export function MarketDetail() {
  const { selector } = useParams({ from: '/markets/$selector' })
  const market = useMarket(selector)
  useLiveMarkets(market.data?.id)
  return (
    <PlayerLayout>
      {market.isLoading ? (
        <main className="container">
          <Loading label="Loading market…" />
        </main>
      ) : isApiError(market.error, 'NOT_FOUND') || (market.error && isApiError(market.error) && market.error.status === 404) ? (
        <main className="container">
          <Empty title="Market not found" action={<Link to="/" className="button lime">Browse markets</Link>}>
            It may have been removed, or the link is wrong.
          </Empty>
        </main>
      ) : market.error || !market.data ? (
        <main className="container">
          <Notice error={market.error} />
        </main>
      ) : (
        <Detail market={market.data} />
      )}
    </PlayerLayout>
  )
}

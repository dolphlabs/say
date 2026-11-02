import { useState } from 'react'
import { Link } from '@tanstack/react-router'
import { dateTime, day, number, ordinal, sedi, signedSedi, timeLeft, tone, weekdayTime } from '../../format'
import { useMe } from '../../session'
import { PlayerLayout } from '../../shell'
import { InboxIcon } from '../../ui/icons'
import { Chip, Empty, Loading, Notice, Pager, SidePill, Tabs } from '../../ui/kit'
import { orderTitle, ratio, useOpenOrders, usePositions } from '../trading/api'
import { cancelStatus, useCancelOrder } from '../trading/MarketPrivate'
import { ledgerLabel, useLedger, useResults, useSummary } from './api'

type Tab = 'positions' | 'orders' | 'settled' | 'activity'

const priceText = (value: number | null) => (value == null ? '—' : `S ${value % 1 ? value.toFixed(1) : value}`)

function EmptyTab({ title, body }: { title: string; body: string }) {
  return (
    <div className="empty-tab">
      <InboxIcon size={28} />
      <strong>{title}</strong>
      <span>{body}</span>
      <Link to="/" className="button lime">
        Browse markets
      </Link>
    </div>
  )
}

function Positions() {
  const positions = usePositions(true)
  const items = positions.data?.items ?? []
  if (positions.isLoading) return <Loading />
  if (positions.error) return <Notice error={positions.error} />
  if (!items.length) return <EmptyTab title="No positions yet" body="Pick a market and take a side." />
  return (
    <div className="table-scroll">
      <table className="data-table">
        <thead>
          <tr>
            <th>Market</th>
            <th>Side</th>
            <th className="num">Shares</th>
            <th className="num">Avg → now</th>
            <th className="num">Value</th>
            <th className="num">Profit / loss</th>
            <th>
              <span className="sr-only">Action</span>
            </th>
          </tr>
        </thead>
        <tbody>
          {items.map((p) => (
            <tr key={`${p.market.id}-${p.outcome}`}>
              <td>
                <Link to="/markets/$selector" params={{ selector: p.market.slug }} className="strong-link">
                  {p.market.question}
                </Link>
                <small className="muted block">
                  Closes {weekdayTime(p.market.closes_at)} · pays {sedi(p.market.redemption_units)} a share
                  {p.qty_in_orders > 0 && ` · ${p.qty_in_orders} shares in a sell order`}
                  {p.proposed_outcome && ` · proposed ${p.proposed_outcome === 'YES' ? 'Yes' : 'No'}`}
                </small>
              </td>
              <td>
                <SidePill outcome={p.outcome} />
              </td>
              <td className="num">{number(p.qty)}</td>
              <td className="num">
                {priceText(ratio(p.avg_price))} → <strong>{priceText(ratio(p.mark))}</strong>
              </td>
              <td className="num">{sedi(p.value)}</td>
              <td className={`num strong ${tone(p.unrealized_pnl)}`}>
                {signedSedi(p.unrealized_pnl)}
                {p.pnl_pct != null && ` (${p.pnl_pct > 0 ? '+' : ''}${p.pnl_pct}%)`}
              </td>
              <td className="num">
                {p.qty_free > 0 && p.market.status === 'OPEN' && (
                  <Link to="/markets/$selector" params={{ selector: p.market.slug }} className="button ghost small">
                    Sell
                  </Link>
                )}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

function Orders() {
  const [cursor, setCursor] = useState('')
  const orders = useOpenOrders(true, '', cursor)
  const cancel = useCancelOrder()
  const items = orders.data?.items ?? []
  if (orders.isLoading) return <Loading />
  if (orders.error) return <Notice error={orders.error} />
  return (
    <>
      {items.length ? (
        <div className="table-scroll">
          <table className="data-table">
            <thead>
              <tr>
                <th>Order</th>
                <th>Filled</th>
                <th>Status</th>
                <th className="num">Held for it</th>
                <th>
                  <span className="sr-only">Action</span>
                </th>
              </tr>
            </thead>
            <tbody>
              {items.map((o) => (
                <tr key={o.id}>
                  <td>
                    <div className="row tight">
                      <SidePill outcome={o.outcome} />
                      <strong>{orderTitle(o)}</strong>
                    </div>
                    <small className="muted block">Placed {dateTime(o.placed_at)}</small>
                  </td>
                  <td>
                    <span className="fill-bar" aria-hidden="true">
                      <span style={{ width: `${o.qty ? Math.round((o.filled_qty / o.qty) * 100) : 0}%` }} />
                    </span>
                    <small>
                      {o.filled_qty} of {o.qty}
                    </small>
                  </td>
                  <td>
                    <span className={o.status === 'PARTIAL' ? 'up strong' : 'warn strong'}>{o.status_label}</span>
                  </td>
                  <td className="num">
                    {o.held.sedi > 0 && sedi(o.held.sedi)}
                    {o.held.shares > 0 && `${o.held.sedi > 0 ? ' + ' : ''}${o.held.shares} shares`}
                    {o.held.sedi === 0 && o.held.shares === 0 && '—'}
                  </td>
                  <td className="num">
                    {o.cancellable && (
                      <button type="button" className="button ghost small" disabled={cancel.isPending && cancel.variables === o.id} onClick={() => cancel.mutate(o.id)}>
                        Cancel
                      </button>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      ) : (
        <EmptyTab title="No open orders" body="Limit orders that haven’t filled yet show up here." />
      )}
      <Notice error={cancel.error} />
      {cancel.data && (
        <p className="muted pad" role="status">
          {cancelStatus(cancel.data)}
        </p>
      )}
      <Pager cursor={cursor} next={orders.data?.next_cursor} onFirst={() => setCursor('')} onNext={setCursor} />
    </>
  )
}

function Settled() {
  const results = useResults(true)
  const items = results.data?.items ?? []
  if (results.isLoading) return <Loading />
  if (results.error) return <Notice error={results.error} />
  if (!items.length) return <EmptyTab title="Nothing settled yet" body="When your markets resolve, wins and losses land here." />
  return (
    <div className="table-scroll">
      <table className="data-table">
        <thead>
          <tr>
            <th>Market</th>
            <th>Your call</th>
            <th>Result</th>
            <th className="num">Paid out</th>
            <th className="num">Profit / loss</th>
          </tr>
        </thead>
        <tbody>
          {items.map((r) => {
            const won = r.result === r.outcome
            const voided = r.result === 'VOID'
            const avg = ratio(r.avg_price)
            return (
              <tr key={`${r.market.id}-${r.outcome}`}>
                <td>
                  <Link to="/markets/$selector" params={{ selector: r.market.slug }} className="strong-link">
                    {r.market.question}
                  </Link>
                  <small className="muted block">Settled {day(r.settled_at)}</small>
                </td>
                <td>
                  {number(r.qty)} {r.outcome === 'YES' ? 'Yes' : 'No'}
                  {avg != null && ` @ ${priceText(avg)}`}
                </td>
                <td>
                  <Chip tone={voided ? 'grey' : won ? 'green' : 'grey'}>{voided ? 'Voided' : won ? 'Won' : 'Lost'}</Chip>
                </td>
                <td className="num">{sedi(r.paid_out)}</td>
                <td className={`num strong ${tone(r.pnl)}`}>{signedSedi(r.pnl)}</td>
              </tr>
            )
          })}
        </tbody>
      </table>
    </div>
  )
}

function Activity() {
  const [cursor, setCursor] = useState('')
  const ledger = useLedger(true, cursor)
  const items = ledger.data?.items ?? []
  if (ledger.isLoading) return <Loading />
  if (ledger.error) return <Notice error={ledger.error} />
  return (
    <>
      {items.length ? (
        <div className="table-scroll">
          <table className="data-table">
            <thead>
              <tr>
                <th>When</th>
                <th>What happened</th>
                <th className="num">Change</th>
                <th className="num">Available after</th>
              </tr>
            </thead>
            <tbody>
              {items.map((l) => (
                <tr key={l.id}>
                  <td className="muted nowrap">{dateTime(l.at).replace(' WAT', '')}</td>
                  <td>
                    {ledgerLabel(l)}
                    {l.held_delta !== 0 && <small className="muted block">{l.held_delta > 0 ? `${sedi(l.held_delta)} held` : `${sedi(-l.held_delta)} released from hold`}</small>}
                  </td>
                  <td className={`num strong ${tone(l.delta)}`}>{signedSedi(l.delta)}</td>
                  <td className="num">{sedi(l.available_after)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      ) : (
        <Empty>No activity yet.</Empty>
      )}
      <p className="muted pad small">Every sedi in and out of your account this season. Money held for an open order leaves “available” when you place it and comes back if you cancel.</p>
      <Pager cursor={cursor} next={ledger.data?.next_cursor} onFirst={() => setCursor('')} onNext={setCursor} />
    </>
  )
}

export function PortfolioPage() {
  const { signedIn, isLoading, error } = useMe()
  const summary = useSummary(signedIn)
  const positions = usePositions(signedIn)
  const orders = useOpenOrders(signedIn)
  const results = useResults(signedIn)
  const [tab, setTab] = useState<Tab>('positions')

  if (isLoading)
    return (
      <PlayerLayout>
        <main className="container">
          <Loading />
        </main>
      </PlayerLayout>
    )
  if (!signedIn)
    return (
      <PlayerLayout>
        <main className="container">
          {error ? (
            <Notice error={error} />
          ) : (
            <Empty title="Your portfolio lives here" action={<Link to="/login" className="button lime">Log in</Link>}>
              Log in to see your positions, orders and results.
            </Empty>
          )}
        </main>
      </PlayerLayout>
    )

  const s = summary.data
  return (
    <PlayerLayout>
      <main className="container stack">
        <div className="page-title">
          <h1>Portfolio</h1>
          {s && (
            <span className="season-pill">
              <span className="dot" aria-hidden="true" />
              Season {ordinal(s.season.ordinal)} · {timeLeft(s.season.ends_at)}
            </span>
          )}
        </div>
        <Notice error={summary.error} />
        <section aria-label="Summary" className="summary-grid">
          <div className="summary-main">
            <span>Total this season</span>
            <strong>{sedi(s?.total)}</strong>
            <span>
              {s?.season_pnl == null ? 'Profit appears once the season has activity' : `${signedSedi(s.season_pnl)} this season`}
              {s?.rank && ` · rank #${number(s.rank.position)} of ${number(s.rank.of)}`}
            </span>
          </div>
          <div className="panel stat">
            <span>Available</span>
            <strong>{sedi(s?.available)}</strong>
            <span>ready to use</span>
          </div>
          <div className="panel stat">
            <span>In open orders</span>
            <strong>{sedi(s?.held)}</strong>
            <span>{s?.held_shares.length ? `plus ${s.held_shares.reduce((n, h) => n + h.qty, 0)} shares` : 'nothing waiting'}</span>
          </div>
          <div className="panel stat">
            <span>Positions</span>
            <strong>{sedi(s?.positions_value)}</strong>
            <span>at last traded price</span>
          </div>
        </section>
        <section className="panel flush" aria-label="Your activity">
          <Tabs
            label="Portfolio sections"
            value={tab}
            onChange={setTab}
            tabs={[
              { key: 'positions', label: 'Positions', count: positions.data?.items.length ?? null },
              { key: 'orders', label: 'Open orders', count: orders.data?.items.length ?? null },
              { key: 'settled', label: 'Settled', count: results.data?.items.length ?? null },
              { key: 'activity', label: 'Activity' },
            ]}
          />
          {tab === 'positions' && <Positions />}
          {tab === 'orders' && <Orders />}
          {tab === 'settled' && <Settled />}
          {tab === 'activity' && <Activity />}
        </section>
      </main>
    </PlayerLayout>
  )
}

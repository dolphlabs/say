import { Link } from '@tanstack/react-router'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { get, post } from '../../api'
import { ago, dateTime, number, sedi } from '../../format'
import { Chip, Empty, Loading, Notice, type Tone } from '../../ui/kit'
import { AdminHeader } from './Shell'

type Summary = {
  given_to_players: number
  bot_budget: { allocated: number; cap: number | null }
  collateral_held: number
  fees_collected: number
  season_grants_next: { at: string; amount: number; approx_players: number; approx_total: number; approval_id: string; status: string } | null
  books_balanced: boolean | null
  incident_banner: string | null
}

type Bot = {
  bot_id: string
  name: string
  market: { id: string; question: string }
  budget: number
  used: number
  holding: { yes: number; no: number }
  spread_ticks: number
  last_quote_age_ms: number
  status: string
  status_label: string
}

type Recon = {
  trading_halted: { halted: boolean; reason: string; changed_at: string }
  run: { id: string; scope: string; status: string; ok: boolean | null; finished_at?: string; checks: { name: string; status: string; count: number; detail: string }[] } | null
}

const BOT_TONE: Record<string, Tone> = { QUOTING: 'green', PAUSED_MANUAL: 'white', PAUSED_ALL: 'white' }

const age = (ms: number) => (ms >= 999_999 ? 'never' : ms < 60_000 ? `${Math.round(ms / 1000)} s` : `${Math.round(ms / 60_000)} m`)

function useTreasuryAction() {
  const client = useQueryClient()
  return useMutation({
    mutationFn: ({ path, body = {} }: { path: string; body?: unknown }) => post(path, body),
    onSuccess: () => {
      void client.invalidateQueries({ queryKey: ['admin', 'bots'] })
      void client.invalidateQueries({ queryKey: ['admin', 'treasury'] })
      void client.invalidateQueries({ queryKey: ['admin', 'recon'] })
    },
  })
}

export function AdminTreasury() {
  const summary = useQuery({ queryKey: ['admin', 'treasury'], queryFn: () => get<Summary>('/v1/admin/treasury/summary'), refetchInterval: 30_000 })
  const bots = useQuery({ queryKey: ['admin', 'bots'], queryFn: () => get<Bot[]>('/v1/admin/bots'), refetchInterval: 10_000 })
  const recon = useQuery({ queryKey: ['admin', 'recon'], queryFn: () => get<Recon>('/v1/admin/reconciliation/latest'), refetchInterval: 30_000 })
  const action = useTreasuryAction()
  const s = summary.data
  const list = bots.data ?? []
  const allPaused = list.length > 0 && list.every((b) => b.status === 'PAUSED_ALL')
  const run = recon.data?.run
  const halted = recon.data?.trading_halted

  return (
    <>
      <AdminHeader
        title="Treasury & bots"
        subtitle="This season · all figures in sedis"
        action={
          <button
            type="button"
            className={allPaused ? 'button lime' : 'button outline-red'}
            disabled={action.isPending || !list.length}
            onClick={() => {
              if (allPaused || window.confirm('Pause every bot and pull their quotes?')) action.mutate({ path: allPaused ? '/v1/admin/bots/resume-all' : '/v1/admin/bots/pause-all', body: { reason: allPaused ? 'operator resume' : 'operator pause' } })
            }}
          >
            {allPaused ? 'Resume all bots' : 'Pause all bots'}
          </button>
        }
      />
      {(s?.incident_banner || halted?.halted) && (
        <section role="alert" className="incident">
          <div>
            <strong>Trading is halted.</strong>
            <span>{s?.incident_banner || halted?.reason}</span>
          </div>
          <Link to="/admin/$section" params={{ section: 'approvals' }} className="button outline-red small">
            Open audit log
          </Link>
        </section>
      )}
      <Notice error={summary.error} />
      <section aria-label="Totals" className="stat-grid">
        <div className="panel stat">
          <span>Given to players</span>
          <strong>{sedi(s?.given_to_players)}</strong>
          <span className="muted small">starting balances this season</span>
        </div>
        <div className="panel stat">
          <span>Bot budget</span>
          <strong>{sedi(s?.bot_budget.allocated)}</strong>
          <span className="muted small">{s?.bot_budget.cap == null ? 'allocated · no season cap set' : `of ${sedi(s.bot_budget.cap)} season cap`}</span>
          {s?.bot_budget.cap ? (
            <span className="bar" aria-hidden="true">
              <span style={{ width: `${Math.min(100, Math.round((s.bot_budget.allocated / s.bot_budget.cap) * 100))}%` }} />
            </span>
          ) : null}
        </div>
        <div className="panel stat">
          <span>Held as collateral</span>
          <strong>{sedi(s?.collateral_held)}</strong>
          <span className="muted small">payout × issued sets, live markets</span>
        </div>
        <div className="panel stat">
          <span>Fees collected</span>
          <strong>{sedi(s?.fees_collected)}</strong>
          <span className="muted small">one fee per order that filled</span>
        </div>
      </section>
      <div className="treasury-grid">
        <section className="panel flush" aria-labelledby="bots-h">
          <div className="panel-head pad">
            <h2 id="bots-h">Market-making bots</h2>
            <span className="muted small">Bots trade through the same order book as players</span>
          </div>
          {bots.isLoading ? (
            <Loading />
          ) : bots.error ? (
            <Notice error={bots.error} />
          ) : list.length ? (
            <div className="table-scroll">
              <table className="data-table">
                <thead>
                  <tr>
                    <th>Bot · market</th>
                    <th>Budget used</th>
                    <th>Holding</th>
                    <th className="num">Spread</th>
                    <th className="num">Last quote</th>
                    <th>Status</th>
                    <th>
                      <span className="sr-only">Action</span>
                    </th>
                  </tr>
                </thead>
                <tbody>
                  {list.map((b) => {
                    const pct = b.budget ? Math.round((b.used / b.budget) * 100) : 0
                    const manual = b.status === 'PAUSED_MANUAL'
                    return (
                      <tr key={`${b.bot_id}-${b.market.id}`}>
                        <td>
                          <strong className="block">{b.name}</strong>
                          <small className="muted">{b.market.question}</small>
                        </td>
                        <td>
                          <span className="small">
                            {number(b.used)} / {number(b.budget)}
                          </span>
                          <span className={`bar ${pct >= 90 ? 'hot' : ''}`} aria-hidden="true">
                            <span style={{ width: `${Math.min(100, pct)}%` }} />
                          </span>
                        </td>
                        <td className="nowrap">
                          <span className="up">{number(b.holding.yes)} Yes</span> · <span className="down">{number(b.holding.no)} No</span>
                        </td>
                        <td className="num">{b.spread_ticks}</td>
                        <td className={`num ${b.last_quote_age_ms > 30_000 ? 'warn' : 'muted'}`}>{age(b.last_quote_age_ms)}</td>
                        <td>
                          <Chip tone={BOT_TONE[b.status] ?? 'orange'}>{b.status_label}</Chip>
                        </td>
                        <td>
                          {b.status !== 'PAUSED_ALL' && (
                            <button
                              type="button"
                              className="button ghost small"
                              disabled={action.isPending}
                              onClick={() => action.mutate({ path: `/v1/admin/bots/${b.bot_id}/markets/${b.market.id}/${manual ? 'resume' : 'pause'}`, body: { reason: manual ? 'operator resume' : 'operator pause' } })}
                            >
                              {manual ? 'Resume' : 'Pause'}
                            </button>
                          )}
                        </td>
                      </tr>
                    )
                  })}
                </tbody>
              </table>
            </div>
          ) : (
            <Empty>No bots assigned to markets.</Empty>
          )}
          <p className="muted small pad">A bot pulls its own quotes if its data goes stale, it hits its holding cap, or its market is paused.</p>
        </section>
        <section className="panel checks" aria-labelledby="checks-h">
          <div className="panel-head">
            <h2 id="checks-h">Books balance?</h2>
            <span className="muted small">{run?.finished_at ? `checked ${ago(run.finished_at)} ago` : run ? run.status : 'never checked'}</span>
          </div>
          {recon.error ? (
            <Notice error={recon.error} />
          ) : run?.checks.length ? (
            <ul>
              {run.checks.map((c) => {
                const ok = c.status === 'ok' || c.status === 'pass' || c.count === 0
                return (
                  <li key={c.name}>
                    <span className={`check-dot ${ok ? 'ok' : 'bad'}`} aria-label={ok ? 'Passed' : 'Failed'}>
                      {ok ? '✓' : '!'}
                    </span>
                    <div>
                      <div className="strong small">{c.name.replaceAll('_', ' ')}</div>
                      <div className="muted tiny">{ok ? c.detail || 'No problems' : `${number(c.count)} · ${c.detail}`}</div>
                    </div>
                  </li>
                )
              })}
            </ul>
          ) : (
            <p className="muted">{s?.books_balanced == null ? 'No completed check yet.' : s.books_balanced ? 'Last check passed.' : 'Last check found problems.'}</p>
          )}
          <button type="button" className="button ghost full" disabled={action.isPending} onClick={() => action.mutate({ path: '/v1/admin/reconciliation/run' })}>
            Run full check now
          </button>
          {action.isSuccess && <p className="muted small">Check requested. Results appear here when it finishes.</p>}
          <Notice error={action.error} />
          {s?.season_grants_next && (
            <div className="grant-box">
              <span className="strong small">Next season grants</span>
              <span className="small">
                {sedi(s.season_grants_next.amount)} to each verified player{s.season_grants_next.at ? ` at ${dateTime(s.season_grants_next.at)}` : ''}. About {number(s.season_grants_next.approx_players)} players, {sedi(s.season_grants_next.approx_total)}.
              </span>
              <Link to="/admin/$section" params={{ section: 'approvals' }} className="muted-link small">
                Waiting on a second approval
              </Link>
            </div>
          )}
        </section>
      </div>
    </>
  )
}

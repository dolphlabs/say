import { useMemo, useState, type FormEvent } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { ApiError, get, query, send, type Page } from '../../api'
import { compactSedi, dateTime, ordinal, sedi } from '../../format'
import { hasRole, useMe } from '../../session'
import { Chip, Empty, Loading, Notice, Pager, type Tone } from '../../ui/kit'
import { useCategories } from '../markets/api'
import { AdminHeader } from './Shell'

type AdminMarket = {
  id: string
  slug: string
  question: string
  category_id: string
  season_id: string
  resolution_source_id: string
  rules: { yes_if: string; no_if: string; edge_cases: string }
  open_at: string | null
  close_at: string | null
  resolve_by: string | null
  redemption_units: number
  min_price: number
  max_price: number
  tick: number
  max_order_qty: number
  liquidity_request: number
  status: string
  status_note: string
  version: number
  created_by: string
  submitted_by: string
}

type SeasonChoice = { id: string; ordinal: number; status: string; starts_at: string; ends_at: string }
type Source = { id: string; name: string; approved: boolean }

const STATUS: Record<string, [string, Tone]> = {
  DRAFT: ['Draft', 'grey'],
  CHANGES_REQUESTED: ['Changes requested', 'orange'],
  REVIEW: ['In review', 'purple'],
  APPROVED: ['Approved', 'purple'],
  FUNDING: ['Funding', 'purple'],
  REJECTED: ['Rejected', 'red'],
  OPEN: ['Open', 'green'],
  SUSPENDED: ['Paused', 'white'],
  CLOSED: ['Closed', 'orange'],
  RESOLUTION_PENDING: ['Resolving', 'orange'],
  DISPUTED: ['Disputed', 'orange'],
  RESOLVED: ['Resolved', 'cyan'],
  SETTLING: ['Settling', 'cyan'],
  SETTLED: ['Settled', 'cyan'],
  VOIDED: ['Voided', 'grey'],
}

const FILTERS = ['', 'DRAFT', 'REVIEW', 'OPEN', 'SUSPENDED', 'RESOLUTION_PENDING', 'SETTLED'] as const

export const StatusChip = ({ status }: { status: string }) => {
  const [label, tone] = STATUS[status] ?? [status, 'grey']
  return <Chip tone={tone}>{label}</Chip>
}

// WAT is a fixed UTC+1 offset, so a wall-clock entry maps to one instant.
const fromWat = (local: string) => (local ? `${local}:00+01:00` : undefined)
const toWat = (iso: string | null) => (iso ? new Date(new Date(iso).getTime() + 3600_000).toISOString().slice(0, 16) : '')

function useAdminAction() {
  const client = useQueryClient()
  return useMutation({
    mutationFn: ({ path, body, method = 'POST' }: { path: string; body: unknown; method?: 'POST' | 'PATCH' }) => send<AdminMarket>(method, path, body),
    onSuccess: () => void client.invalidateQueries({ queryKey: ['admin', 'markets'] }),
  })
}

function FieldErrors({ error }: { error: unknown }) {
  if (!(error instanceof ApiError)) return <Notice error={error} />
  return (
    <Notice>
      {error.message}
      {error.fields.length > 0 && (
        <ul className="field-errors">
          {error.fields.map((f) => (
            <li key={f.field}>
              {f.field}: {f.message ?? f.reason}
            </li>
          ))}
        </ul>
      )}
    </Notice>
  )
}

function Editor({ market, onDone }: { market?: AdminMarket; onDone: () => void }) {
  const { user } = useMe()
  const categories = useCategories()
  const seasons = useQuery({ queryKey: ['admin', 'seasons'], queryFn: () => get<{ items: SeasonChoice[] }>('/v1/admin/seasons') })
  const sources = useQuery({ queryKey: ['admin', 'sources'], queryFn: () => get<Source[]>('/v1/admin/resolution-sources') })
  const action = useAdminAction()
  const [question, setQuestion] = useState(market?.question ?? '')
  const [category, setCategory] = useState(market?.category_id ?? '')
  const [season, setSeason] = useState(market?.season_id ?? '')
  const [source, setSource] = useState(market?.resolution_source_id ?? '')
  const [yes, setYes] = useState(market?.rules.yes_if ?? '')
  const [no, setNo] = useState(market?.rules.no_if ?? '')
  const [edge, setEdge] = useState(market?.rules.edge_cases ?? '')
  const [openAt, setOpenAt] = useState(toWat(market?.open_at ?? null))
  const [closeAt, setCloseAt] = useState(toWat(market?.close_at ?? null))
  const [resolveBy, setResolveBy] = useState(toWat(market?.resolve_by ?? null))
  const [V, setV] = useState(market?.redemption_units || 100)
  const [minP, setMinP] = useState(market?.min_price || 1)
  const [tick, setTick] = useState(market?.tick || 1)
  const [maxQty, setMaxQty] = useState(market?.max_order_qty || 10000)
  const [liquidity, setLiquidity] = useState(market?.liquidity_request || 0)

  const chosenSeason = seasons.data?.items.find((s) => s.id === season)
  const closeBad = !!chosenSeason && !!closeAt && new Date(fromWat(closeAt)!).getTime() > new Date(chosenSeason.ends_at).getTime()
  const maxP = V - minP
  const example = Math.round(V * 0.6)
  const super_ = hasRole(user, 'super_admin', 'treasury')

  const body = () => ({
    ...(market ? { version: market.version } : {}),
    question,
    category_id: category || null,
    season_id: season || null,
    resolution_source_id: source || null,
    rules: { yes_if: yes, no_if: no, edge_cases: edge },
    open_at: fromWat(openAt) ?? null,
    close_at: fromWat(closeAt) ?? null,
    resolve_by: fromWat(resolveBy) ?? null,
    redemption_units: V,
    min_price: minP,
    max_price: maxP,
    tick,
    max_order_qty: maxQty,
    liquidity_request: liquidity > 0 ? liquidity : null,
  })

  const save = async (submit: boolean) => {
    const saved = market
      ? await action.mutateAsync({ path: `/v1/admin/markets/${market.id}`, body: body(), method: 'PATCH' })
      : await action.mutateAsync({ path: '/v1/admin/markets', body: body() })
    if (submit) await action.mutateAsync({ path: `/v1/admin/markets/${saved.id}/submit`, body: { version: saved.version } })
    onDone()
  }

  const submitForm = (e: FormEvent) => {
    e.preventDefault()
    void save(true).catch(() => undefined)
  }

  return (
    <form className="panel admin-form" onSubmit={submitForm} aria-labelledby="form-h">
      <div className="panel-head">
        <h2 id="form-h">{market ? 'Edit draft' : 'New market'}</h2>
        <button type="button" className="button ghost small" onClick={onDone}>
          Close
        </button>
      </div>
      <label>
        Question
        <input value={question} onChange={(e) => setQuestion(e.target.value)} maxLength={140} required />
        <span className="hint">One yes-or-no question. Name the event, the teams and the day.</span>
      </label>
      <div className="two">
        <label>
          Category
          <select value={category} onChange={(e) => setCategory(e.target.value)} required>
            <option value="">Choose…</option>
            {categories.data?.map((c) => (
              <option key={c.id} value={c.id}>
                {c.name}
              </option>
            ))}
          </select>
        </label>
        <label>
          Season
          <select value={season} onChange={(e) => setSeason(e.target.value)} required>
            <option value="">Choose…</option>
            {seasons.data?.items.map((s) => (
              <option key={s.id} value={s.id}>
                Season {ordinal(s.ordinal)} · ends {dateTime(s.ends_at)}
              </option>
            ))}
          </select>
        </label>
      </div>
      <label>
        Yes if
        <textarea rows={2} value={yes} onChange={(e) => setYes(e.target.value)} required />
      </label>
      <label>
        No if
        <textarea rows={2} value={no} onChange={(e) => setNo(e.target.value)} required />
      </label>
      <label>
        If it doesn’t go ahead
        <textarea rows={2} value={edge} onChange={(e) => setEdge(e.target.value)} required />
        <span className="hint">Cover postponement, abandonment and anything else that could leave the answer unclear.</span>
      </label>
      <label>
        Resolution source
        <select value={source} onChange={(e) => setSource(e.target.value)} required>
          <option value="">Choose an approved source…</option>
          {sources.data
            ?.filter((s) => s.approved)
            .map((s) => (
              <option key={s.id} value={s.id}>
                {s.name}
              </option>
            ))}
        </select>
      </label>
      <div className="three">
        <label>
          Trading opens (WAT)
          <input type="datetime-local" value={openAt} onChange={(e) => setOpenAt(e.target.value)} />
        </label>
        <label>
          Trading closes (WAT)
          <input type="datetime-local" value={closeAt} onChange={(e) => setCloseAt(e.target.value)} aria-invalid={closeBad} />
        </label>
        <label>
          Result due by (WAT)
          <input type="datetime-local" value={resolveBy} onChange={(e) => setResolveBy(e.target.value)} />
        </label>
      </div>
      {closeBad && chosenSeason && (
        <p className="warn" role="status">
          That’s after Season {ordinal(chosenSeason.ordinal)} ends ({dateTime(chosenSeason.ends_at)}). Pick an earlier close or move it to the next season.
        </p>
      )}
      <fieldset>
        <legend>Payout and prices · locked once it opens</legend>
        <div className="two">
          <label>
            Winning share pays
            <span className="stepper">
              <button type="button" aria-label="Lower payout" onClick={() => setV(Math.max(10, V - 10))}>
                −
              </button>
              <input type="number" min={10} max={1000} step={10} value={V} onChange={(e) => setV(Math.max(10, Math.min(1000, Number(e.target.value) || 10)))} />
              <button type="button" aria-label="Raise payout" onClick={() => setV(Math.min(1000, V + 10))}>
                +
              </button>
            </span>
          </label>
          <label>
            Price step
            <input type="number" min={1} value={tick} onChange={(e) => setTick(Math.max(1, Number(e.target.value) || 1))} />
          </label>
        </div>
        <div className="two">
          <label>
            Lowest price
            <input type="number" min={1} max={Math.floor(V / 2)} value={minP} onChange={(e) => setMinP(Math.max(1, Math.min(Math.floor(V / 2), Number(e.target.value) || 1)))} />
          </label>
          <label>
            Highest price
            <input type="number" value={maxP} readOnly aria-describedby="price-hint" />
          </label>
        </div>
        <label>
          Most shares in one order
          <input type="number" min={1} value={maxQty} onChange={(e) => setMaxQty(Math.max(1, Number(e.target.value) || 1))} />
        </label>
        <span className="hint" id="price-hint">
          Prices run S {minP}–{maxP}, which always add up to the payout. A Yes at S {example} reads as {Math.round((example / V) * 100)}% to players. Orders outside the range are rejected, never rounded in.
        </span>
      </fieldset>
      {super_ ? (
        <fieldset>
          <legend>Starting liquidity</legend>
          <label>
            Market-maker budget
            <input type="number" min={0} step={1000} value={liquidity} onChange={(e) => setLiquidity(Math.max(0, Number(e.target.value) || 0))} />
          </label>
          <span className="hint">0 for none. A budget comes out of the season’s bot budget and needs treasury approval.</span>
        </fieldset>
      ) : (
        <p className="muted small">As a creator you draft and submit. A curator reviews it, and treasury decides on starting liquidity.</p>
      )}
      <FieldErrors error={action.error} />
      <div className="row">
        <button type="submit" className="button lime" disabled={closeBad || action.isPending}>
          Send for review
        </button>
        <button type="button" className="button ghost" disabled={action.isPending} onClick={() => void save(false).catch(() => undefined)}>
          Save draft
        </button>
      </div>
      <span className="hint">Another admin has to approve it before it opens. You can’t approve your own market.</span>
    </form>
  )
}

function Inspector({ market, onEdit, onClose }: { market: AdminMarket; onEdit: () => void; onClose: () => void }) {
  const { user } = useMe()
  const action = useAdminAction()
  const [reason, setReason] = useState('')
  const run = (name: string) => action.mutate({ path: `/v1/admin/markets/${market.id}/${name}`, body: { version: market.version, reason } }, { onSuccess: () => setReason('') })
  const reviewer = hasRole(user, 'curator', 'admin', 'super_admin')
  const editable = ['DRAFT', 'CHANGES_REQUESTED'].includes(market.status) && market.created_by === user?.id
  const own = market.submitted_by === user?.id
  return (
    <section className="panel admin-form" aria-labelledby="insp-h">
      <div className="panel-head">
        <h2 id="insp-h">{market.question || 'Untitled draft'}</h2>
        <button type="button" className="button ghost small" onClick={onClose}>
          Close
        </button>
      </div>
      <div className="row tight">
        <StatusChip status={market.status} />
        <span className="muted small">version {market.version}</span>
      </div>
      {market.status_note && <p className="muted">{market.status_note}</p>}
      <dl className="facts">
        <div>
          <dt>Closes</dt>
          <dd>{dateTime(market.close_at)}</dd>
        </div>
        <div>
          <dt>Pays</dt>
          <dd>{sedi(market.redemption_units)}</dd>
        </div>
        <div>
          <dt>Prices</dt>
          <dd>
            S {market.min_price}–{market.max_price}
          </dd>
        </div>
        <div>
          <dt>Liquidity asked</dt>
          <dd>{market.liquidity_request ? compactSedi(market.liquidity_request) : 'None'}</dd>
        </div>
      </dl>
      <div className="rules-text small">
        <p>
          <strong className="up">Yes</strong> if {market.rules.yes_if || '—'}
        </p>
        <p>
          <strong className="down">No</strong> if {market.rules.no_if || '—'}
        </p>
        {market.rules.edge_cases && <p>{market.rules.edge_cases}</p>}
      </div>
      {editable && (
        <button type="button" className="button lime" onClick={onEdit}>
          Edit draft
        </button>
      )}
      {(market.status === 'REVIEW' && reviewer) || market.status === 'OPEN' || market.status === 'SUSPENDED' ? (
        <>
          <label>
            Reason (logged with your name)
            <textarea rows={2} value={reason} onChange={(e) => setReason(e.target.value)} />
          </label>
          <div className="row wrap">
            {market.status === 'REVIEW' && reviewer && (
              <>
                <button type="button" className="button lime" disabled={own || action.isPending} onClick={() => run('approve')} title={own ? 'You submitted this, so someone else has to approve it.' : undefined}>
                  Approve
                </button>
                <button type="button" className="button ghost" disabled={!reason.trim() || action.isPending} onClick={() => run('request-changes')}>
                  Request changes
                </button>
                <button type="button" className="button outline-red" disabled={!reason.trim() || action.isPending} onClick={() => run('reject')}>
                  Reject
                </button>
              </>
            )}
            {market.status === 'OPEN' && (
              <button type="button" className="button outline-red" disabled={!reason.trim() || action.isPending} onClick={() => run('suspend')}>
                Pause trading
              </button>
            )}
            {market.status === 'SUSPENDED' && (
              <button type="button" className="button lime" disabled={!reason.trim() || action.isPending} onClick={() => run('resume')}>
                Resume trading
              </button>
            )}
          </div>
          {own && market.status === 'REVIEW' && <p className="muted small">You submitted this, so someone else has to approve it.</p>}
        </>
      ) : null}
      <FieldErrors error={action.error} />
    </section>
  )
}

export function AdminMarkets() {
  const { user } = useMe()
  const categories = useCategories()
  const [status, setStatus] = useState<(typeof FILTERS)[number]>('')
  const [cursor, setCursor] = useState('')
  const [panel, setPanel] = useState<{ mode: 'new' } | { mode: 'view' | 'edit'; id: string } | null>(null)
  const creatorOnly = hasRole(user, 'creator') && !hasRole(user, 'curator', 'admin', 'super_admin')
  const list = useQuery({
    queryKey: ['admin', 'markets', status, cursor],
    queryFn: () => get<Page<AdminMarket>>(`/v1/admin/markets${query({ status, cursor })}`),
  })
  const names = useMemo(() => new Map(categories.data?.map((c) => [c.id, c.name])), [categories.data])
  const items = list.data?.items ?? []
  const selected = panel && panel.mode !== 'new' ? items.find((m) => m.id === panel.id) : undefined

  return (
    <>
      <AdminHeader
        title={creatorOnly ? 'Your markets' : 'Markets'}
        subtitle="Markets must close before their season ends."
        action={
          <button type="button" className="button lime" onClick={() => setPanel({ mode: 'new' })}>
            + New market
          </button>
        }
      />
      <div className="admin-split">
        <section aria-label="Market list" className="stack">
          <div role="group" aria-label="Filter by status" className="filter-chips">
            {FILTERS.map((f) => (
              <button
                type="button"
                key={f || 'all'}
                aria-pressed={status === f}
                onClick={() => {
                  setStatus(f)
                  setCursor('')
                }}
              >
                {f ? STATUS[f][0] : 'All'}
              </button>
            ))}
          </div>
          {list.isLoading ? (
            <Loading />
          ) : list.error ? (
            <Notice error={list.error} />
          ) : items.length ? (
            <div className="panel flush table-scroll">
              <table className="data-table admin-table">
                <thead>
                  <tr>
                    <th>Market</th>
                    <th>Status</th>
                    <th className="num">Pays</th>
                    <th>Closes</th>
                  </tr>
                </thead>
                <tbody>
                  {items.map((m) => (
                    <tr key={m.id} className={selected?.id === m.id ? 'selected' : ''}>
                      <td>
                        <button type="button" className="row-button" onClick={() => setPanel({ mode: 'view', id: m.id })}>
                          <strong>{m.question || 'Untitled draft'}</strong>
                          <small className="muted">{names.get(m.category_id) ?? 'No category'}</small>
                        </button>
                      </td>
                      <td>
                        <StatusChip status={m.status} />
                      </td>
                      <td className="num">{m.redemption_units ? sedi(m.redemption_units) : '—'}</td>
                      <td className="nowrap">{dateTime(m.close_at)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          ) : (
            <Empty title="No markets here">Use “New market” to draft one.</Empty>
          )}
          <Pager cursor={cursor} next={list.data?.next_cursor} onFirst={() => setCursor('')} onNext={setCursor} />
        </section>
        <div>
          {panel?.mode === 'new' && <Editor onDone={() => setPanel(null)} />}
          {panel?.mode === 'edit' && selected && <Editor market={selected} onDone={() => setPanel({ mode: 'view', id: selected.id })} />}
          {panel?.mode === 'view' && selected && <Inspector market={selected} onEdit={() => setPanel({ mode: 'edit', id: selected.id })} onClose={() => setPanel(null)} />}
          {!panel && <Empty>Pick a market to review it, or start a new one.</Empty>}
        </div>
      </div>
    </>
  )
}


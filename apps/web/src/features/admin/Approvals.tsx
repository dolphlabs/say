import { useState } from 'react'
import { Link } from '@tanstack/react-router'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { get, isApiError, post, query, type Page } from '../../api'
import { ago, dateTime } from '../../format'
import { Chip, Empty, Loading, Notice, Pager, type Tone } from '../../ui/kit'
import { AdminHeader } from './Shell'

export type Approval = {
  id: string
  kind: string
  title: string
  detail: string
  requested_by: { username: string; role: string }
  requested_at: number
  can_decide: boolean
  cannot_decide_reason?: string
  subject_link: string
  payload_hash: string
  status: string
}

type AuditRow = { id: string; actor_id: string; actor_kind: string; role_at_time: string; area: string; action: string; target_type: string; target_id: string; created_at: number }

const AREAS = ['', 'Money', 'Markets', 'Resolution', 'Bots', 'Access'] as const

const AREA_TONE: Record<string, Tone> = { Money: 'lime', Markets: 'blue', Resolution: 'orange', Bots: 'purple', Access: 'pink' }

const kindArea = (kind: string) => (/market|liquidity/.test(kind) ? 'Markets' : /role/.test(kind) ? 'Access' : 'Money')

const isTotpError = (error: unknown) => isApiError(error) && error.code.toUpperCase() === 'APPROVALS.TOTP_REQUIRED'

function Requests() {
  const client = useQueryClient()
  const list = useQuery({ queryKey: ['admin', 'approvals'], queryFn: () => get<Page<Approval>>('/v1/admin/approvals'), refetchInterval: 30_000 })
  const [notes, setNotes] = useState<Record<string, string>>({})
  const [outcome, setOutcome] = useState<Record<string, string>>({})
  const decide = useMutation({
    mutationFn: ({ a, approve }: { a: Approval; approve: boolean }) =>
      post(`/v1/admin/approvals/${a.id}/${approve ? 'approve' : 'reject'}`, approve ? { payload_hash: a.payload_hash, note: notes[a.id] ?? '' } : { payload_hash: a.payload_hash, reason: notes[a.id] ?? '' }),
    onSuccess: (_r, { a, approve }) => {
      setOutcome((o) => ({ ...o, [a.id]: approve ? 'Approved by you just now. It goes ahead.' : `Rejected by you. @${a.requested_by.username} has been told.` }))
      void client.invalidateQueries({ queryKey: ['admin'] })
    },
  })
  const pending = (list.data?.items ?? []).filter((a) => a.status === 'pending' || outcome[a.id])
  return (
    <section aria-labelledby="ap-h" className="stack">
      <h2 id="ap-h">Waiting for a second person</h2>
      {isTotpError(decide.error) ? (
        <Notice>
          Approvals need a fresh authenticator code in this session. <Link to="/settings">Verify it in Settings</Link>, then try again.
        </Notice>
      ) : (
        <Notice error={decide.error} />
      )}
      {list.isLoading ? (
        <Loading />
      ) : list.error ? (
        <Notice error={list.error} />
      ) : pending.length ? (
        <div className="request-grid">
          {pending.map((a) => (
            <article key={a.id} className="panel request">
              <div className="row spread">
                <Chip tone={AREA_TONE[kindArea(a.kind)]}>{kindArea(a.kind)}</Chip>
                <span className="muted tiny">{ago(a.requested_at)} ago</span>
              </div>
              <h3>{a.title}</h3>
              <p className="small">{a.detail}</p>
              <span className="muted small">
                Asked by {a.requested_by.username} · {a.requested_by.role.replaceAll('_', ' ')}
              </span>
              {outcome[a.id] ? (
                <p className="small strong up">{outcome[a.id]}</p>
              ) : a.can_decide ? (
                <>
                  <label className="sr-only" htmlFor={`note-${a.id}`}>
                    Note or reason
                  </label>
                  <input id={`note-${a.id}`} placeholder="Note (required to reject)" value={notes[a.id] ?? ''} onChange={(e) => setNotes((n) => ({ ...n, [a.id]: e.target.value }))} />
                  <div className="two">
                    <button type="button" className="button lime" disabled={decide.isPending} onClick={() => decide.mutate({ a, approve: true })}>
                      Approve
                    </button>
                    <button type="button" className="button outline-red" disabled={decide.isPending || !(notes[a.id] ?? '').trim()} onClick={() => decide.mutate({ a, approve: false })}>
                      Reject
                    </button>
                  </div>
                </>
              ) : (
                <p className="cannot small">{a.cannot_decide_reason || 'You can’t decide this request.'}</p>
              )}
            </article>
          ))}
        </div>
      ) : (
        <Empty>Nothing is waiting for a second approval.</Empty>
      )}
    </section>
  )
}

function AuditLog() {
  const [area, setArea] = useState<(typeof AREAS)[number]>('')
  const [cursor, setCursor] = useState('')
  const log = useQuery({ queryKey: ['admin', 'audit', area, cursor], queryFn: () => get<Page<AuditRow>>(`/v1/admin/audit${query({ area, cursor })}`) })
  const exportCsv = useMutation({ mutationFn: () => post<{ export_id: string; status: string; download_url: string }>(`/v1/admin/audit/export${query({ area })}`, {}) })
  const items = log.data?.items ?? []
  return (
    <section aria-labelledby="log-h" className="stack">
      <div className="section-head">
        <h2 id="log-h">Audit log</h2>
        <div className="row wrap">
          <div role="group" aria-label="Filter log" className="filter-chips small">
            {AREAS.map((a) => (
              <button
                type="button"
                key={a || 'all'}
                aria-pressed={area === a}
                onClick={() => {
                  setArea(a)
                  setCursor('')
                }}
              >
                {a || 'All'}
              </button>
            ))}
          </div>
          <button type="button" className="button ghost small" disabled={exportCsv.isPending} onClick={() => exportCsv.mutate()}>
            Export CSV
          </button>
        </div>
      </div>
      <Notice error={exportCsv.error} />
      {exportCsv.data && (
        <p className="small" role="status">
          Export {exportCsv.data.status.toLowerCase()} ·{' '}
          <a href={`/v1/admin/audit/export/${encodeURIComponent(exportCsv.data.export_id)}`} className="muted-link">
            Download CSV
          </a>
        </p>
      )}
      {log.isLoading ? (
        <Loading />
      ) : log.error ? (
        <Notice error={log.error} />
      ) : items.length ? (
        <div className="panel flush table-scroll">
          <table className="data-table">
            <thead>
              <tr>
                <th>When</th>
                <th>Who</th>
                <th>Did what</th>
                <th>Target</th>
              </tr>
            </thead>
            <tbody>
              {items.map((r) => (
                <tr key={r.id}>
                  <td className="muted nowrap">{dateTime(r.created_at).replace(' WAT', '')}</td>
                  <td>
                    <span className="block strong small">{r.actor_id ? r.actor_id.slice(0, 8) : 'system'}</span>
                    <span className="muted tiny">{(r.role_at_time || r.actor_kind).replaceAll('_', ' ')}</span>
                  </td>
                  <td>
                    <Chip tone={AREA_TONE[r.area] ?? 'grey'}>{r.area}</Chip> {r.action.replaceAll('_', ' ').toLowerCase()}
                  </td>
                  <td className="muted small">
                    {r.target_type.toLowerCase().replaceAll('_', ' ')} {r.target_id ? r.target_id.slice(0, 8) : ''}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      ) : (
        <Empty>No entries for this filter.</Empty>
      )}
      <Pager cursor={cursor} next={log.data?.next_cursor || null} onFirst={() => setCursor('')} onNext={setCursor} />
      <p className="muted small">Entries can’t be edited or deleted.</p>
    </section>
  )
}

export function AdminApprovals() {
  return (
    <>
      <AdminHeader title="Approvals & audit log" subtitle="Money and market launches need two people. Nobody approves their own request." />
      <Requests />
      <AuditLog />
    </>
  )
}

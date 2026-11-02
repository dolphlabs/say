import { useEffect, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { get, post } from '../../api'
import { clock, dateTime, number, sedi, timeLeft } from '../../format'
import { hasRole, useMe } from '../../session'
import { Chip, Empty, Loading, Notice, useNow, type Tone } from '../../ui/kit'
import { AdminHeader } from './Shell'

type QueueRow = { market_id: string; slug: string; question: string; state: string; stage_label: string; meta: string; conflict: boolean; overdue: boolean }

type Evidence = { id: string; url: string; retrieved_at: string; http_status: number; snapshot_ref: string; sha256: string; finding: string; verdict: string; collected_by: string }
type Dispute = { id: string; account_id: string; reason: string; link_url: string; decision: string; decision_note: string; decided_at: string; created_at: string }
type Preview = { outcome: string; winners: number; payout_total: number; collateral_released: number; refunds_total: number; shortfall: number; needs_second_approval: boolean }

type Case = {
  market_id: string
  question: string
  state: string
  version: number
  conflict: boolean
  overdue: boolean
  dispute_until: string
  proposed_outcome: string
  proposed_reason: string
  hold_reason: string
  final_outcome: string
  final_reason: string
  decided_at: string
  evidence: Evidence[]
  disputes: Dispute[]
  preview: Preview
}

type Settlement = { state: string; done: boolean; winners_count: number; payout_total: number; refunds_total: number; collateral_released: number; shortfall: number; error_message: string }

const STAGE_TONE: Record<string, Tone> = { COLLECTING: 'cyan', PROPOSED: 'orange', AWAITING_FINAL: 'orange', HELD: 'white', OVERDUE: 'red' }

const verdictTone = (v: string): Tone => (/yes/i.test(v) ? 'green' : /no/i.test(v) ? 'red' : 'grey')

const shortHash = (h: string) => (h.length > 8 ? `${h.slice(0, 4)}…${h.slice(-4)}` : h)

function useCase(id: string) {
  return useQuery({ queryKey: ['admin', 'resolution', id], queryFn: () => get<Case>(`/v1/admin/resolutions/${id}`), refetchInterval: 15_000 })
}

function useResolutionAction(id: string) {
  const client = useQueryClient()
  return useMutation({
    mutationFn: ({ action, body }: { action: string; body: unknown }) => post(`/v1/admin/resolutions/${id}/${action}`, body),
    onSuccess: () => {
      void client.invalidateQueries({ queryKey: ['admin', 'resolution', id] })
      void client.invalidateQueries({ queryKey: ['admin', 'resolutions'] })
    },
  })
}

function Steps({ c, settlement }: { c: Case; settlement?: Settlement }) {
  const now = useNow(1000)
  const windowOpen = !!c.dispute_until && new Date(c.dispute_until).getTime() > now
  const steps: [string, string, 'done' | 'now' | 'todo'][] = [
    ['Trading closed', '', 'done'],
    ['Evidence in', c.evidence.length ? `${c.evidence.length} source${c.evidence.length > 1 ? 's' : ''}` : 'waiting', c.evidence.length ? 'done' : 'now'],
    [c.proposed_outcome ? `Proposed: ${c.proposed_outcome === 'YES' ? 'Yes' : c.proposed_outcome === 'NO' ? 'No' : c.proposed_outcome}` : 'Proposal', c.proposed_outcome ? '' : 'resolver', c.proposed_outcome ? 'done' : c.evidence.length ? 'now' : 'todo'],
    ['Dispute window', c.dispute_until ? (windowOpen ? timeLeft(c.dispute_until, now) : `ended ${clock(c.dispute_until)}`) : '', c.dispute_until ? (windowOpen ? 'now' : 'done') : 'todo'],
    ['Final decision', c.final_outcome ? (c.final_outcome === 'YES' ? 'Yes' : c.final_outcome === 'NO' ? 'No' : c.final_outcome) : 'super admin', c.final_outcome ? 'done' : c.dispute_until && !windowOpen ? 'now' : 'todo'],
    ['Paid out', settlement ? (settlement.done ? 'done' : settlement.state.toLowerCase()) : 'automatic', settlement?.done ? 'done' : c.final_outcome ? 'now' : 'todo'],
  ]
  return (
    <ol className="steps" aria-label="Progress">
      {steps.map(([label, when, state]) => (
        <li key={label} className={state}>
          <span className="step-dot" aria-hidden="true" />
          <span className="strong small">{label}</span>
          {when && <span className="muted tiny">{when}</span>}
        </li>
      ))}
    </ol>
  )
}

function CaseFile({ id, selected, onToggle }: { id: string; selected: string[]; onToggle: (id: string) => void }) {
  const { user } = useMe()
  const c = useCase(id)
  const action = useResolutionAction(id)
  const [url, setUrl] = useState('')
  const [note, setNote] = useState('')
  const [decisionNote, setDecisionNote] = useState('')
  const settlement = useQuery({ queryKey: ['admin', 'settlement', id], queryFn: () => get<Settlement>(`/v1/admin/settlements/${id}`), enabled: !!c.data?.final_outcome, retry: false, refetchInterval: 10_000 })
  if (c.isLoading) return <Loading />
  if (c.error || !c.data) return <Notice error={c.error} />
  const d = c.data
  const canDecide = hasRole(user, 'super_admin')
  const openDisputes = d.disputes.filter((x) => !x.decision)
  return (
    <section className="panel case" aria-labelledby="case-h">
      <div className="case-head">
        <h2 id="case-h">{d.question}</h2>
        <div className="row tight wrap">
          {d.conflict && <Chip tone="orange">Sources disagree</Chip>}
          {d.overdue && <Chip tone="red">Overdue</Chip>}
          {d.hold_reason && <Chip tone="white">Held · {d.hold_reason}</Chip>}
        </div>
      </div>
      <Steps c={d} settlement={settlement.data} />
      <div className="case-block">
        <div className="panel-head">
          <h3>Evidence</h3>
          <button type="button" className="button ghost small" disabled={action.isPending} onClick={() => action.mutate({ action: 'evidence/refresh', body: {} })}>
            Collect again
          </button>
        </div>
        {d.evidence.length ? (
          d.evidence.map((e) => (
            <div className="evidence-row" key={e.id}>
              {!d.proposed_outcome && (
                <input type="checkbox" aria-label={`Use ${e.url} as supporting evidence`} checked={selected.includes(e.id)} onChange={() => onToggle(e.id)} />
              )}
              <Chip tone={verdictTone(e.verdict)}>{e.verdict || 'No verdict'}</Chip>
              <div className="grow">
                <div className="strong small">{new URL(e.url, window.location.href).hostname}</div>
                <div className="small">{e.finding || 'No finding recorded.'}</div>
                <div className="muted tiny">
                  Retrieved {dateTime(e.retrieved_at)} · snapshot {shortHash(e.sha256)} · by {e.collected_by || 'system'}
                </div>
              </div>
              <a href={e.url} target="_blank" rel="noreferrer" className="muted-link small">
                Open
              </a>
            </div>
          ))
        ) : (
          <p className="muted">No evidence yet. Collect again, or add a link.</p>
        )}
        <form
          className="row wrap"
          onSubmit={(e) => {
            e.preventDefault()
            action.mutate({ action: 'evidence', body: { url, note: note || null } }, { onSuccess: () => (setUrl(''), setNote('')) })
          }}
        >
          <label className="grow">
            <span className="sr-only">Evidence link</span>
            <input type="url" placeholder="https://source/report" value={url} onChange={(e) => setUrl(e.target.value)} required />
          </label>
          <label className="grow">
            <span className="sr-only">Note</span>
            <input placeholder="Note (optional)" value={note} onChange={(e) => setNote(e.target.value)} />
          </label>
          <button type="submit" className="button ghost small" disabled={!url || action.isPending}>
            Add link
          </button>
        </form>
      </div>
      <div className="case-block">
        <h3>
          Disputes {openDisputes.length > 0 && <Chip tone="orange">{openDisputes.length} open</Chip>}
        </h3>
        {d.disputes.length ? (
          d.disputes.map((x) => (
            <div className="dispute" key={x.id}>
              <div className="row spread">
                <span className="small strong">Holder {x.account_id.slice(0, 8)}</span>
                <span className="muted tiny">{dateTime(x.created_at)}</span>
              </div>
              <p>“{x.reason}”</p>
              {x.link_url && (
                <a href={x.link_url} target="_blank" rel="noreferrer" className="muted-link small">
                  Their source
                </a>
              )}
              {x.decision ? (
                <span className="small muted">
                  {x.decision === 'ACCEPT' ? 'Upheld' : 'Dismissed'} · {x.decision_note}
                </span>
              ) : canDecide ? (
                <div className="row wrap">
                  <input className="grow" placeholder="Decision note" value={decisionNote} onChange={(e) => setDecisionNote(e.target.value)} aria-label="Decision note" />
                  <button type="button" className="button ghost small" disabled={!decisionNote.trim() || action.isPending} onClick={() => action.mutate({ action: `disputes/${x.id}/decide`, body: { decision: 'REJECT', note: decisionNote } })}>
                    Dismiss
                  </button>
                  <button type="button" className="button orange small" disabled={!decisionNote.trim() || action.isPending} onClick={() => action.mutate({ action: `disputes/${x.id}/decide`, body: { decision: 'ACCEPT', note: decisionNote } })}>
                    Uphold
                  </button>
                </div>
              ) : (
                <span className="small warn">A super admin decides on this before finalizing.</span>
              )}
            </div>
          ))
        ) : (
          <p className="muted">No disputes.</p>
        )}
      </div>
      {settlement.data && (
        <div className="case-block">
          <h3>Settlement</h3>
          <p className="small">
            {settlement.data.done ? 'Done' : `In progress · ${settlement.data.state.toLowerCase()}`} · {number(settlement.data.winners_count)} winners · {sedi(settlement.data.payout_total)} paid · {sedi(settlement.data.refunds_total)} refunded
          </p>
          {settlement.data.error_message && <Notice>{settlement.data.error_message}</Notice>}
        </div>
      )}
      <Notice error={action.error} />
    </section>
  )
}

type Choice = 'YES' | 'NO' | 'HOLD' | 'VOID'

function Decision({ id, evidenceIds }: { id: string; evidenceIds: string[] }) {
  const { user } = useMe()
  const c = useCase(id)
  const action = useResolutionAction(id)
  const now = useNow(1000)
  const [choice, setChoice] = useState<Choice>('YES')
  const [reason, setReason] = useState('')
  useEffect(() => {
    setReason('')
    setChoice('YES')
  }, [id])
  if (!c.data) return null
  const d = c.data
  const isSuper = hasRole(user, 'super_admin')
  const proposing = !d.proposed_outcome && !d.final_outcome
  const windowOpen = !!d.dispute_until && new Date(d.dispute_until).getTime() > now
  const openDisputes = d.disputes.some((x) => !x.decision)
  const preview = d.preview

  if (d.final_outcome) {
    return (
      <section className="panel decision" aria-labelledby="decide-h">
        <h2 id="decide-h">Final decision</h2>
        <div className="window-box done">
          <strong>{d.final_outcome === 'YES' ? 'Yes' : d.final_outcome === 'NO' ? 'No' : d.final_outcome}</strong>
          <span>{d.final_reason}</span>
          <span className="tiny">Decided {dateTime(d.decided_at)}</span>
        </div>
      </section>
    )
  }

  const options: [Choice, string, string, boolean][] = [
    ['YES', 'Yes', `Winning Yes shares pay out.`, false],
    ['NO', 'No', `Winning No shares pay out.`, false],
    ['HOLD', 'Hold for more evidence', 'Keeps the market closed. Nothing is paid.', false],
    ['VOID', 'Void and refund', 'Not available yet: the refund rules for resold shares aren’t final.', true],
  ]

  let blocked = !reason.trim()
  let note = ''
  if (choice === 'HOLD') note = 'Holding is logged with your name.'
  else if (proposing) {
    if (!evidenceIds.length) [blocked, note] = [true, 'Tick at least one piece of evidence that supports it.']
    else note = 'Players get a window to dispute before it can be made final.'
  } else if (!isSuper) [blocked, note] = [true, 'Only a super admin can make a result final. You can gather evidence or hold.']
  else if (windowOpen) [blocked, note] = [true, 'Locked until the dispute window closes.']
  else if (openDisputes) [blocked, note] = [true, 'Decide on the open disputes first.']
  else note = 'This is logged with your name and can’t be undone.'

  const label = choice === 'HOLD' ? 'Hold market' : proposing ? `Propose ${choice === 'YES' ? 'Yes' : 'No'}` : `Finalize as ${choice === 'YES' ? 'Yes' : 'No'}`
  const submit = () => {
    if (choice === 'HOLD') action.mutate({ action: 'hold', body: { reason, version: d.version } })
    else if (proposing) action.mutate({ action: 'propose', body: { outcome: choice, reason, evidence_ids: evidenceIds, version: d.version } })
    else if (window.confirm(`Finalize this market as ${choice === 'YES' ? 'Yes' : 'No'} and start paying out?`)) action.mutate({ action: 'finalize', body: { outcome: choice, reason, void_reason: null, version: d.version } })
  }

  return (
    <section className="panel decision" aria-labelledby="decide-h">
      <h2 id="decide-h">{proposing ? 'Propose a result' : 'Final decision'}</h2>
      {!proposing && (
        <div className={`window-box ${windowOpen ? 'open' : 'done'}`}>
          <strong>{windowOpen ? `Dispute window open · ${timeLeft(d.dispute_until, now)}` : 'Dispute window closed'}</strong>
          <span>
            Proposed {d.proposed_outcome === 'YES' ? 'Yes' : 'No'} · {d.proposed_reason}
          </span>
        </div>
      )}
      <div role="radiogroup" aria-label="Outcome" className="radio-list">
        {options.map(([key, text, hint, disabled]) => (
          <button type="button" role="radio" key={key} aria-checked={choice === key} disabled={disabled} onClick={() => setChoice(key)}>
            <span className="ring" aria-hidden="true" />
            <span>
              <span className="strong">{text}</span>
              <span className="muted small block">{hint}</span>
            </span>
          </button>
        ))}
      </div>
      <label>
        Reason (shown to players)
        <textarea rows={3} value={reason} onChange={(e) => setReason(e.target.value)} />
      </label>
      {choice !== 'HOLD' && preview.outcome && (
        <div className="settle-preview">
          <span className="strong small">What settling {preview.outcome === 'YES' ? 'Yes' : preview.outcome === 'NO' ? 'No' : preview.outcome} does</span>
          <span className="small">
            {sedi(preview.payout_total)} to {number(preview.winners)} players · collateral released {sedi(preview.collateral_released)}
          </span>
          {preview.shortfall > 0 && <span className="small warn">Treasury shortfall {sedi(preview.shortfall)}{preview.needs_second_approval ? ' · needs a second approval' : ''}</span>}
        </div>
      )}
      <button type="button" className="button lime full" disabled={blocked || action.isPending} onClick={submit}>
        {label}
      </button>
      <span className="muted small">{note}</span>
      <Notice error={action.error} />
    </section>
  )
}

export function AdminResolution() {
  const queue = useQuery({ queryKey: ['admin', 'resolutions', ''], queryFn: () => get<QueueRow[]>('/v1/admin/resolutions'), refetchInterval: 30_000 })
  const [selected, setSelected] = useState('')
  const [evidence, setEvidence] = useState<string[]>([])
  const rows = queue.data ?? []
  const active = selected || rows[0]?.market_id || ''
  useEffect(() => setEvidence([]), [active])
  return (
    <>
      <AdminHeader title="Resolution" subtitle="Evidence is collected automatically. A person proposes, players get a window to dispute, a super admin makes it final." />
      {queue.isLoading ? (
        <Loading />
      ) : queue.error ? (
        <Notice error={queue.error} />
      ) : !rows.length ? (
        <Empty title="Queue is clear">Markets show up here when trading closes.</Empty>
      ) : (
        <div className="resolution-grid">
          <section aria-label="Queue" className="queue">
            {rows.map((r) => (
              <button type="button" key={r.market_id} aria-pressed={active === r.market_id} onClick={() => setSelected(r.market_id)}>
                <Chip tone={r.overdue ? 'red' : (STAGE_TONE[r.state] ?? 'grey')}>{r.stage_label || r.state}</Chip>
                <span className="strong small">{r.question}</span>
                <span className="muted tiny">{r.meta}</span>
              </button>
            ))}
          </section>
          {active && <CaseFile id={active} selected={evidence} onToggle={(id) => setEvidence((list) => (list.includes(id) ? list.filter((x) => x !== id) : [...list, id]))} />}
          {active && <Decision id={active} evidenceIds={evidence} />}
        </div>
      )}
    </>
  )
}

import { useState, type FormEvent } from 'react'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { isApiError, post } from '../../api'
import { clock, dateTime, sedi, timeLeft } from '../../format'
import { Chip, Notice, useNow } from '../../ui/kit'
import { usePublicResolution, type Market } from './api'

const RESOLVING = new Set(['CLOSED', 'RESOLUTION_PENDING', 'DISPUTED', 'RESOLVED', 'SETTLING', 'SETTLED', 'VOIDED'])

const outcomeLabel = (o: string) => (o === 'YES' ? 'Yes' : o === 'NO' ? 'No' : o === 'VOID' ? 'Void' : o)

type Banner = { tone: 'orange' | 'grey' | 'green'; kicker: string; title: string; body: string; disputable: boolean }

export function useResolutionBanner(market: Market): Banner | null {
  const resolution = usePublicResolution(market.id, RESOLVING.has(market.status))
  const now = useNow(1000)
  const r = resolution.data
  if (market.status === 'SUSPENDED') {
    return { tone: 'grey', kicker: 'Trading paused', title: market.status_note || 'Trading is on hold', body: 'Your open orders are on hold. Nothing fills until trading resumes.', disputable: false }
  }
  if (r?.final) {
    const won = outcomeLabel(r.final.outcome)
    return {
      tone: 'green',
      kicker: market.status === 'SETTLED' ? 'Settled' : 'Result final',
      title: r.final.outcome === 'VOID' ? 'Market voided' : `${won} won`,
      body: r.final.outcome === 'VOID' ? r.final.reason : `${r.final.reason} Winning shares pay ${sedi(market.redemption_units)} each.`,
      disputable: false,
    }
  }
  if (r?.state === 'PROPOSED' && r.proposed_outcome) {
    const open = !!r.dispute_until && new Date(r.dispute_until).getTime() > now
    return {
      tone: 'orange',
      kicker: 'Result proposed',
      title: outcomeLabel(r.proposed_outcome),
      body: open
        ? `If nobody disputes it, it’s final in ${timeLeft(r.dispute_until, now).replace(' left', '')} and winning shares pay ${sedi(market.redemption_units)}.`
        : 'The dispute window has closed. A super admin makes the final call.',
      disputable: open,
    }
  }
  if (RESOLVING.has(market.status)) {
    return { tone: 'orange', kicker: 'Trading closed', title: 'Waiting for the result', body: market.resolve_by ? `Expected by ${dateTime(market.resolve_by)}.` : 'Evidence is being collected.', disputable: false }
  }
  return null
}

export function StatusBanner({ banner, onDispute }: { banner: Banner; onDispute: () => void }) {
  return (
    <section aria-label="Market status" className={`banner tone-${banner.tone}`}>
      <div>
        <span className="kicker">{banner.kicker}</span>
        <strong>{banner.title}</strong>
        <span>{banner.body}</span>
      </div>
      {banner.disputable && (
        <div className="banner-actions">
          <a href="#evidence" className="button dim">
            See evidence
          </a>
          <button type="button" className="button outline-orange" onClick={onDispute}>
            Dispute result
          </button>
        </div>
      )}
    </section>
  )
}

export function Evidence({ market, signedIn, disputeOpen, onCloseDispute }: { market: Market; signedIn: boolean; disputeOpen: boolean; onCloseDispute: () => void }) {
  const resolution = usePublicResolution(market.id, RESOLVING.has(market.status))
  const client = useQueryClient()
  const [reason, setReason] = useState('')
  const [link, setLink] = useState('')
  const dispute = useMutation({
    mutationFn: () => post(`/v1/markets/${market.id}/disputes`, { reason: reason.trim(), link_url: link.trim() || null }),
    onSuccess: () => {
      setReason('')
      setLink('')
      void client.invalidateQueries({ queryKey: ['resolution', market.id] })
    },
  })
  const r = resolution.data
  if (!r || !r.evidence.length) return null
  const submit = (e: FormEvent) => {
    e.preventDefault()
    dispute.mutate()
  }
  const length = reason.trim().length
  return (
    <section id="evidence" className="panel evidence" aria-labelledby="evidence-h">
      <h2 id="evidence-h">Evidence</h2>
      <ul>
        {r.evidence.map((e) => (
          <li key={e.sha256 || e.retrieved_at + e.source}>
            <Chip tone={e.verdict.toUpperCase().includes('YES') ? 'green' : e.verdict.toUpperCase().includes('NO') ? 'red' : 'grey'}>{e.verdict}</Chip>
            <div>
              <strong>{e.source}</strong>
              <span>{e.finding}</span>
              <small className="muted">Retrieved {clock(e.retrieved_at)} · snapshot {e.sha256.slice(0, 4)}…{e.sha256.slice(-4)}</small>
            </div>
            {e.snapshot_url && (
              <a href={e.snapshot_url} target="_blank" rel="noreferrer" className="muted-link">
                Open snapshot
              </a>
            )}
          </li>
        ))}
      </ul>
      {disputeOpen && r.state === 'PROPOSED' && (
        <form className="dispute-form" onSubmit={submit}>
          <h3>Dispute this result</h3>
          {!signedIn ? (
            <p className="muted">Log in to dispute. Only people who held shares in this market can.</p>
          ) : dispute.isSuccess ? (
            <p className="success" role="status">
              Dispute sent. A super admin reviews it before the result is final.
            </p>
          ) : (
            <>
              <label>
                What’s wrong with it?
                <textarea rows={3} minLength={20} maxLength={500} value={reason} onChange={(e) => setReason(e.target.value)} required />
                <small className={length > 0 && length < 20 ? 'warn' : 'muted'}>{length < 20 ? `${20 - length} more characters needed` : `${500 - length} characters left`}</small>
              </label>
              <label>
                Link to a source (optional)
                <input type="url" inputMode="url" placeholder="https://" value={link} onChange={(e) => setLink(e.target.value)} />
              </label>
              {isApiError(dispute.error, 'NOT_ELIGIBLE_TO_DISPUTE') ? <Notice>Only people who held shares in this market can dispute it.</Notice> : <Notice error={dispute.error} />}
              <div className="row">
                <button type="submit" className="button orange" disabled={length < 20 || dispute.isPending}>
                  {dispute.isPending ? 'Sending…' : 'Send dispute'}
                </button>
                <button type="button" className="button ghost" onClick={onCloseDispute}>
                  Cancel
                </button>
              </div>
            </>
          )}
        </form>
      )}
    </section>
  )
}

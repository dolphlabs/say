import { afterEach, describe, expect, it, vi } from 'vitest'
import { cleanup, fireEvent, screen, waitFor } from '@testing-library/react'
import { AdminApprovals } from '../src/features/admin/Approvals'
import { AdminTreasury } from '../src/features/admin/Treasury'
import { json, renderWithApp, stubFetch } from './render'

afterEach(() => {
  cleanup()
  vi.unstubAllGlobals()
})

const request = (id: string, extra: Record<string, unknown>) => ({ id, kind: 'bot_topup', title: `Request ${id}`, detail: 'Budget', requested_by: { username: 'ada.ops', role: 'treasury' }, requested_at: Date.now() - 60_000, subject_link: '', status: 'pending', payload_hash: `hash-${id}`, ...extra })

describe('approvals', () => {
  it('should send the displayed payload hash and block self-approval', async () => {
    const fetcher = stubFetch((url, init) => {
      if (url === '/v1/admin/approvals' && !init?.method) return { items: [request('a', { can_decide: true }), request('b', { can_decide: false, cannot_decide_reason: 'You asked for this, so someone else has to approve it.' })] }
      if (url.startsWith('/v1/admin/audit')) return { items: [], next_cursor: '' }
      return { status: 'approved' }
    })
    renderWithApp(() => <AdminApprovals />)
    expect(await screen.findByText('You asked for this, so someone else has to approve it.')).toBeTruthy()
    const approve = screen.getAllByRole('button', { name: 'Approve' })
    expect(approve).toHaveLength(1)
    fireEvent.click(approve[0])
    await waitFor(() =>
      expect(fetcher).toHaveBeenCalledWith('/v1/admin/approvals/a/approve', expect.objectContaining({ method: 'POST', body: JSON.stringify({ payload_hash: 'hash-a', note: '' }) })),
    )
    expect(await screen.findByText(/Approved by you just now/)).toBeTruthy()
  })

  it('should point to settings when a fresh authenticator code is needed', async () => {
    stubFetch((url, init) => {
      if (url === '/v1/admin/approvals' && !init?.method) return { items: [request('a', { can_decide: true })] }
      if (url.startsWith('/v1/admin/audit')) return { items: [], next_cursor: '' }
      return json({ error: { code: 'APPROVALS.TOTP_REQUIRED', message: 'Recent TOTP 2FA verification required.' } }, 403)
    })
    renderWithApp(() => <AdminApprovals />)
    fireEvent.click(await screen.findByRole('button', { name: 'Approve' }))
    expect(await screen.findByText(/Verify it in Settings/)).toBeTruthy()
  })

  it('should require a reason to reject', async () => {
    stubFetch((url, init) => {
      if (url === '/v1/admin/approvals' && !init?.method) return { items: [request('a', { can_decide: true })] }
      return { items: [], next_cursor: '' }
    })
    renderWithApp(() => <AdminApprovals />)
    const reject = (await screen.findByRole('button', { name: 'Reject' })) as HTMLButtonElement
    expect(reject.disabled).toBe(true)
    fireEvent.change(screen.getByLabelText('Note or reason'), { target: { value: 'Budget already covered' } })
    expect(reject.disabled).toBe(false)
  })
})

describe('treasury', () => {
  const summary = { given_to_players: 3_180_000, bot_budget: { allocated: 502_000, cap: null }, collateral_held: 0, fees_collected: 12_410, season_grants_next: null, books_balanced: null, incident_banner: null }
  const bot = { bot_id: 'b', name: 'mm-football-01', market: { id: 'm', question: 'Example market' }, budget: 25_000, used: 18_400, holding: { yes: 140, no: 95 }, spread_ticks: 2, last_quote_age_ms: 2000, status: 'QUOTING', status_label: 'Quoting', params_version: 1 }

  it('should show recorded figures and say when no cap is set', async () => {
    stubFetch((url) => {
      if (url.endsWith('/treasury/summary')) return summary
      if (url.endsWith('/bots')) return [bot]
      return { trading_halted: { halted: false, reason: '', changed_at: '' }, run: null }
    })
    renderWithApp(() => <AdminTreasury />)
    expect(await screen.findByText('S 3,180,000')).toBeTruthy()
    expect(screen.getByText(/no season cap set/)).toBeTruthy()
    expect(await screen.findByText('mm-football-01')).toBeTruthy()
    expect(screen.getByText('No completed check yet.')).toBeTruthy()
  })

  it('should pause one bot for its market', async () => {
    const fetcher = stubFetch((url) => {
      if (url.endsWith('/treasury/summary')) return summary
      if (url.endsWith('/bots')) return [bot]
      if (url.endsWith('/pause')) return { ok: true }
      return { trading_halted: { halted: false, reason: '', changed_at: '' }, run: null }
    })
    renderWithApp(() => <AdminTreasury />)
    fireEvent.click(await screen.findByRole('button', { name: 'Pause' }))
    await waitFor(() => expect(fetcher).toHaveBeenCalledWith('/v1/admin/bots/b/markets/m/pause', expect.objectContaining({ method: 'POST' })))
  })

  it('should surface a trading halt', async () => {
    stubFetch((url) => {
      if (url.endsWith('/treasury/summary')) return { ...summary, incident_banner: 'Collateral check failed' }
      if (url.endsWith('/bots')) return []
      return { trading_halted: { halted: true, reason: 'Collateral check failed', changed_at: '' }, run: null }
    })
    renderWithApp(() => <AdminTreasury />)
    expect((await screen.findByRole('alert')).textContent).toContain('Collateral check failed')
  })
})

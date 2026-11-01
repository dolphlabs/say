import { afterEach, describe, expect, it, vi } from 'vitest'
import { cleanup, fireEvent, screen, waitFor } from '@testing-library/react'
import { OrderPanel } from '../src/features/trading/OrderPanel'
import type { Book, Market } from '../src/features/markets/api'
import { client, json, renderWithApp, stubFetch, user } from './render'

const market: Market = {
  id: '11111111-1111-4111-a111-111111111111',
  slug: 'enyimba',
  question: 'Will Enyimba beat Rivers United?',
  category: { id: 'c', name: 'Football', icon: 'football' },
  status: 'OPEN',
  status_note: '',
  closes_at: '2026-11-08T15:00:00Z',
  closing_soon: false,
  redemption_units: 100,
  last_price: 57,
  chance_pct: 57,
  yes_ask: 58,
  no_ask: 44,
  volume_units: 1000,
  change_24h: null,
  rules: { yes_if: 'Enyimba win.', no_if: 'They do not.', edge_cases: '' },
  resolve_by: null,
  price_band: { min: 1, max: 99, tick: 1 },
  max_order_qty: 10000,
  fee_units: 1,
}

const book: Book = { market_id: market.id, last_price: 57, health: 'READY', mode: 'OPEN', bids: [{ yes_price: 38, qty: 100 }], asks: [{ yes_price: 40, qty: 100 }] }

const filled = { id: 'o-1', order_id: 'o-1', market_id: market.id, status: 'FILLED', status_label: 'Filled', outcome: 'YES', side: 'BUY', price: 58, qty: 1, remaining: 0, filled_qty: 1, principal: 58, fee_charged: 1, avg_price: 58, held: { sedi: 0, shares: 0 }, placed_at: '2026-11-01T10:00:00Z', cancellable: false }

function setup(handler: Parameters<typeof stubFetch>[0]) {
  const fetcher = stubFetch(handler)
  const qc = client()
  qc.setQueryData(['me'], user)
  const view = renderWithApp(() => <OrderPanel market={market} book={book} positions={[]} prefill={null} />, qc)
  return { fetcher, view, qc }
}

const summary = { available: 500, held: 0, held_shares: [], positions_value: 0, total: 500, season_pnl: 0, starting_grant: 1000, rank: null, season: { ordinal: 1, status: 'ACTIVE', ends_at: '2026-11-15T00:00:00Z' } }

afterEach(() => {
  cleanup()
  sessionStorage.clear()
  vi.unstubAllGlobals()
})

describe('order panel', () => {
  it('should reuse the idempotency key after an uncertain failure and reconcile a pending order', async () => {
    const keys: string[] = []
    let attempts = 0
    const handler = (url: string, init?: RequestInit) => {
      if (url === '/v1/me/portfolio/summary') return summary
      if (url === `/v1/markets/${market.id}/orders`) {
        keys.push(new Headers(init?.headers).get('Idempotency-Key') ?? '')
        attempts += 1
        if (attempts === 1) return new TypeError('Network unavailable')
        return json({ order_id: 'o-1', command_id: 'c-1', status: 'ADMITTED', existing: true }, 202)
      }
      if (url === '/v1/orders/o-1') return filled
      return {}
    }
    const first = setup(handler)
    fireEvent.change(await screen.findByLabelText('Amount'), { target: { value: '100' } })
    fireEvent.click(screen.getByRole('button', { name: 'Buy Yes · S 100' }))
    expect(await screen.findByText(/may have gone through/i)).toBeTruthy()
    first.view.unmount()

    const qc = client()
    qc.setQueryData(['me'], user)
    renderWithApp(() => <OrderPanel market={market} book={book} positions={[]} prefill={null} />, qc)
    await waitFor(() => expect((screen.getByLabelText('Amount') as HTMLInputElement).value).toBe('100'))
    expect(screen.getByText(/may have gone through/i)).toBeTruthy()
    fireEvent.click(screen.getByRole('button', { name: 'Buy Yes · S 100' }))
    await waitFor(() => expect(keys).toHaveLength(2))
    expect(keys[0]).toMatch(/^[0-9a-f-]{36}$/)
    expect(keys[1]).toBe(keys[0])
    expect(await screen.findByText('Bought 1 Yes')).toBeTruthy()
    expect(sessionStorage.length).toBe(0)
  })

  it('should refuse a different order while an earlier one is unresolved', async () => {
    let posts = 0
    setup((url) => {
      if (url === '/v1/me/portfolio/summary') return summary
      if (url.endsWith('/orders')) {
        posts += 1
        return new TypeError('offline')
      }
      return {}
    })
    fireEvent.click(await screen.findByRole('button', { name: 'Buy Yes · S 100' }))
    await screen.findByText(/may have gone through/i)
    fireEvent.change(screen.getByLabelText('Amount'), { target: { value: '60' } })
    fireEvent.click(screen.getByRole('button', { name: 'Buy Yes · S 60' }))
    expect(await screen.findByText(/previous order may already have been accepted/i)).toBeTruthy()
    expect(posts).toBe(1)
  })

  it('should forget the key after a definite rejection and show the server message', async () => {
    const keys: string[] = []
    setup((url, init) => {
      if (url === '/v1/me/portfolio/summary') return summary
      if (url.endsWith('/orders')) {
        keys.push(new Headers(init?.headers).get('Idempotency-Key') ?? '')
        return json({ error: { code: 'MARKET_SUSPENDED', message: 'Trading on this market is paused.' } }, 409)
      }
      return {}
    })
    fireEvent.click(await screen.findByRole('button', { name: 'Buy Yes · S 100' }))
    expect((await screen.findByRole('alert')).textContent).toContain('Trading on this market is paused.')
    fireEvent.click(screen.getByRole('button', { name: 'Buy Yes · S 100' }))
    await waitFor(() => expect(keys).toHaveLength(2))
    expect(keys[1]).not.toBe(keys[0])
  })

  it('should block a buy above the available balance', async () => {
    setup((url) => (url === '/v1/me/portfolio/summary' ? { ...summary, available: 40 } : {}))
    expect(await screen.findByText('That’s more than your S 40 balance.')).toBeTruthy()
    expect((screen.getByRole('button', { name: 'Buy Yes · S 100' }) as HTMLButtonElement).disabled).toBe(true)
  })
})

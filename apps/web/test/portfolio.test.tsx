import { afterEach, expect, it, vi } from 'vitest'
import { cleanup, fireEvent, screen, waitFor } from '@testing-library/react'
import { PortfolioPage } from '../src/features/portfolio/Portfolio'
import { client, renderWithApp, stubFetch, user } from './render'

afterEach(() => {
  cleanup()
  vi.unstubAllGlobals()
})

const order = (id: string) => ({ id, order_id: id, market_id: 'm', status: 'OPEN', status_label: 'Waiting to match', outcome: 'YES', side: 'BUY', price: 54, qty: 6, remaining: 6, filled_qty: 0, principal: 0, fee_charged: 0, avg_price: null, held: { sedi: 325, shares: 0 }, placed_at: '2026-11-01T10:00:00Z', cancellable: true })

it('should page open orders with the server cursor and cancel one', async () => {
  const fetcher = stubFetch((url, init) => {
    if (url === '/v1/me') return user
    if (url === '/v1/me/portfolio/summary') return { available: 100, held: 325, held_shares: [], positions_value: 0, total: 425, season_pnl: null, starting_grant: 1000, rank: null, season: { ordinal: 1, status: 'ACTIVE', ends_at: '2027-01-01T00:00:00Z' } }
    if (url.startsWith('/v1/me/orders')) return { items: [order(url.includes('cursor=') ? 'o-2' : 'o-1')], next_cursor: url.includes('cursor=') ? null : 'next-page' }
    if (url.startsWith('/v1/orders/') && init?.method === 'DELETE') return new Response(JSON.stringify({ order_id: 'o-2', command_id: 'c', status: 'CANCEL_PENDING', existing: false }), { status: 202 })
    return { items: [] }
  })
  const qc = client()
  qc.setQueryData(['me'], user)
  renderWithApp(() => <PortfolioPage />, qc)
  fireEvent.click(await screen.findByRole('tab', { name: /Open orders/ }))
  fireEvent.click(await screen.findByRole('button', { name: 'Next page' }))
  await waitFor(() => expect(fetcher).toHaveBeenCalledWith('/v1/me/orders?status=open&cursor=next-page', expect.anything()))
  expect(await screen.findByRole('button', { name: 'First page' })).toBeTruthy()
  fireEvent.click(await screen.findByRole('button', { name: 'Cancel' }))
  expect(await screen.findByText(/Cancelling · the held amount comes back/)).toBeTruthy()
  expect(screen.getByText('Profit appears once the season has activity')).toBeTruthy()
})

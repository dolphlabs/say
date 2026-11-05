import { afterEach, describe, expect, it, vi } from 'vitest'
import { cleanup, fireEvent, screen, waitFor } from '@testing-library/react'
import { AdminSources } from '../src/features/admin/Sources'
import { json, renderWithApp, stubFetch } from './render'

afterEach(() => {
  cleanup()
  vi.unstubAllGlobals()
})

const pending = { id: 's1', name: 'NPFL official results', url_pattern: 'https://npfl.ng/results', kind: 'html', approved: false }
const approved = { id: 's2', name: 'NiMet', url_pattern: 'https://nimet.gov.ng', kind: 'json', approved: true }

describe('resolution sources', () => {
  it('should offer approval only for sources still waiting', async () => {
    stubFetch(() => [pending, approved])
    renderWithApp(() => <AdminSources />)
    expect(await screen.findByText('NPFL official results')).toBeTruthy()
    expect(screen.getAllByRole('button', { name: 'Approve' })).toHaveLength(1)
    expect(screen.getByText('1 waiting for approval')).toBeTruthy()
  })

  it('should explain that the person who added a source cannot approve it', async () => {
    stubFetch((url, init) =>
      url.endsWith('/approve') && init?.method === 'POST'
        ? json({ error: { code: 'SELF_APPROVAL_FORBIDDEN', message: 'forbidden' } }, 403)
        : [pending],
    )
    renderWithApp(() => <AdminSources />)
    fireEvent.click(await screen.findByRole('button', { name: 'Approve' }))
    expect((await screen.findByRole('alert')).textContent).toContain('another curator has to approve it')
  })

  it('should create a source as unapproved with the entered details', async () => {
    const fetcher = stubFetch((url, init) => (url === '/v1/admin/resolution-sources' && init?.method === 'POST' ? { ...pending, id: 's3' } : []))
    renderWithApp(() => <AdminSources />)
    fireEvent.click(await screen.findByRole('button', { name: 'New source' }))
    fireEvent.change(screen.getByLabelText(/^Name/), { target: { value: ' Premier League results ' } })
    fireEvent.change(screen.getByLabelText(/^Address/), { target: { value: 'https://premierleague.com/results' } })
    fireEvent.click(screen.getByRole('button', { name: 'Add source' }))
    await waitFor(() =>
      expect(fetcher).toHaveBeenCalledWith(
        '/v1/admin/resolution-sources',
        expect.objectContaining({ method: 'POST', body: JSON.stringify({ name: 'Premier League results', url_pattern: 'https://premierleague.com/results', kind: 'html' }) }),
      ),
    )
  })
})

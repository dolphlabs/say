import { afterEach, describe, expect, it, vi } from 'vitest'
import { cleanup, fireEvent, screen, waitFor } from '@testing-library/react'
import { Settings } from '../src/features/profile/Settings'
import { json, renderWithApp, stubFetch, user } from './render'

afterEach(() => {
  cleanup()
  vi.unstubAllGlobals()
})

describe('account settings', () => {
  it('should update one notification channel and keep the other', async () => {
    const fetcher = stubFetch((url, init) => {
      if (url === '/v1/me/notification-prefs' && !init?.method) return [{ kind: 'order_filled', label: 'Order filled', hint: 'When any part matches.', in_app: true, email: false }]
      if (url === '/v1/me/notification-prefs') return json(undefined, 204)
      return {}
    })
    renderWithApp(() => <Settings user={user} />)
    fireEvent.click(await screen.findByRole('switch', { name: 'Order filled by email' }))
    await waitFor(() =>
      expect(fetcher).toHaveBeenCalledWith('/v1/me/notification-prefs', expect.objectContaining({ method: 'PUT', body: JSON.stringify({ kind: 'order_filled', in_app: true, email: true }) })),
    )
  })

  it('should surface a failed password change without ending the session', async () => {
    stubFetch((url) => (url === '/v1/me/password' ? json({ error: { code: 'INVALID_CREDENTIALS', message: 'Current password is incorrect.' } }, 401) : []))
    renderWithApp(() => <Settings user={user} />)
    fireEvent.click(await screen.findByRole('button', { name: 'Change password' }))
    fireEvent.change(screen.getByLabelText('Current password'), { target: { value: 'wrong' } })
    fireEvent.change(screen.getByLabelText('New password'), { target: { value: 'new-password' } })
    fireEvent.click(screen.getByRole('button', { name: 'Save password' }))
    expect((await screen.findByRole('alert')).textContent).toContain('Current password is incorrect.')
  })

  it('should keep account deletion disabled', async () => {
    stubFetch(() => [])
    renderWithApp(() => <Settings user={user} />)
    expect((await screen.findByRole('button', { name: 'Delete account' }) as HTMLButtonElement).disabled).toBe(true)
  })

  it('should only show the authenticator to staff', async () => {
    stubFetch(() => [])
    const view = renderWithApp(() => <Settings user={user} />)
    await screen.findByText('Account')
    expect(screen.queryByText('Authenticator')).toBeNull()
    view.unmount()
    renderWithApp(() => <Settings user={{ ...user, roles: ['treasury'] } as typeof user} />)
    expect(await screen.findByText('Authenticator')).toBeTruthy()
  })
})

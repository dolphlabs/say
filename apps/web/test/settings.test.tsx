import { afterEach, describe, expect, it, vi } from 'vitest'
import { cleanup, fireEvent, screen, waitFor } from '@testing-library/react'
import { Settings, uploadPhoto } from '../src/features/profile/Settings'
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

  it('should delete the account only after the username is typed', async () => {
    const fetcher = stubFetch((url, init) => (url === '/v1/me' && init?.method === 'DELETE' ? json({ status: 'DELETING' }, 202) : []))
    renderWithApp(() => <Settings user={user} />)
    fireEvent.click(await screen.findByRole('button', { name: 'Delete account' }))
    const confirm = screen.getByRole('button', { name: 'Delete my account' }) as HTMLButtonElement
    expect(confirm.disabled).toBe(true)
    fireEvent.change(screen.getByLabelText(/to confirm/), { target: { value: 'someone-else' } })
    expect(confirm.disabled).toBe(true)
    fireEvent.change(screen.getByLabelText(/to confirm/), { target: { value: user.username.toUpperCase() } })
    expect(confirm.disabled).toBe(false)
    fireEvent.click(confirm)
    await waitFor(() => expect(fetcher).toHaveBeenCalledWith('/v1/me', expect.objectContaining({ method: 'DELETE' })))
  })

  it('should keep the account when deletion is backed out of', async () => {
    const fetcher = stubFetch(() => [])
    renderWithApp(() => <Settings user={user} />)
    fireEvent.click(await screen.findByRole('button', { name: 'Delete account' }))
    fireEvent.click(screen.getByRole('button', { name: 'Keep my account' }))
    expect(screen.getByRole('button', { name: 'Delete account' })).toBeTruthy()
    expect(fetcher).not.toHaveBeenCalledWith('/v1/me', expect.objectContaining({ method: 'DELETE' }))
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

  it('should upload a photo straight to Cloudinary and save the signed result', async () => {
    const fetcher = stubFetch((url, init) => {
      if (url === '/v1/me/avatar/upload') return { upload_url: 'https://api.cloudinary.com/v1_1/demo/image/upload', fields: { api_key: '123', signature: 'sig', public_id: 'say/avatars/u1' } }
      if (url === 'https://api.cloudinary.com/v1_1/demo/image/upload') {
        const form = init?.body as FormData
        expect(form.get('public_id')).toBe('say/avatars/u1')
        expect(form.get('file')).toBeInstanceOf(File)
        return { public_id: 'say/avatars/u1', version: 17, signature: 'resp-sig' }
      }
      if (url === '/v1/me/avatar') return { avatar_url: 'https://res.cloudinary.com/demo/image/upload/v17/say/avatars/u1' }
      return []
    })
    const url = await uploadPhoto(new File(['x'], 'me.png', { type: 'image/png' }))
    expect(url).toContain('res.cloudinary.com')
    expect(fetcher).toHaveBeenCalledWith('/v1/me/avatar', expect.objectContaining({ method: 'PUT', body: JSON.stringify({ public_id: 'say/avatars/u1', version: '17', signature: 'resp-sig' }) }))
  })

  it('should refuse a non-image or oversized file before asking the server', async () => {
    const fetcher = stubFetch(() => [])
    await expect(uploadPhoto(new File(['x'], 'notes.pdf', { type: 'application/pdf' }))).rejects.toThrow('JPG, PNG or WebP')
    await expect(uploadPhoto(new File([new Uint8Array(5 * 1024 * 1024 + 1)], 'big.png', { type: 'image/png' }))).rejects.toThrow('under 5 MB')
    expect(fetcher).not.toHaveBeenCalled()
  })

  it('should show the Cloudinary error when an upload is rejected', async () => {
    stubFetch((url) => {
      if (url === '/v1/me/avatar/upload') return { upload_url: 'https://api.cloudinary.com/v1_1/demo/image/upload', fields: {} }
      if (url.startsWith('https://api.cloudinary.com')) return json({ error: { message: 'Invalid image file' } }, 400)
      return []
    })
    await expect(uploadPhoto(new File(['x'], 'me.png', { type: 'image/png' }))).rejects.toThrow('Invalid image file')
  })
})

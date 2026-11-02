import { describe, expect, it } from 'vitest'
import { QueryClient, QueryObserver } from '@tanstack/react-query'
import { endSession, hasRole, installSession, roleLabel, type User } from '../src/session'

const base: User = { id: 'new', username: 'new', email: 'new@example.test', email_verified: true, has_password: true, google_linked: false, username_changeable_at: null }

describe('session', () => {
  it('should replace the signed-in user and drop the previous user’s private data', async () => {
    const client = new QueryClient()
    client.setQueryData(['me'], { ...base, id: 'old' })
    client.setQueryData(['summary'], { available: 100 })
    client.setQueryData(['orders', '', ''], { items: [] })
    const observer = new QueryObserver(client, { queryKey: ['me'], enabled: false })
    const stop = observer.subscribe(() => undefined)
    await installSession(client, base)
    expect(observer.getCurrentResult().data).toMatchObject({ id: 'new' })
    expect(client.getQueryData(['summary'])).toBeUndefined()
    expect(client.getQueryData(['orders', '', ''])).toBeUndefined()
    stop()
    client.clear()
  })

  it('should forget private data when the session ends', async () => {
    const client = new QueryClient()
    client.setQueryData(['me'], base)
    client.setQueryData(['positions'], { items: [1] })
    client.setQueryData(['markets', 'trending', ''], { pages: [] })
    await endSession(client)
    expect(client.getQueryData(['me'])).toBeNull()
    expect(client.getQueryData(['positions'])).toBeUndefined()
    expect(client.getQueryData(['markets', 'trending', ''])).toBeDefined()
  })

  it('should treat super admin as admin and label the highest role', () => {
    const op = { ...base, roles: ['creator', 'super_admin'] } as User
    expect(hasRole(op, 'admin')).toBe(true)
    expect(hasRole({ ...base, roles: ['creator'] } as User, 'admin')).toBe(false)
    expect(hasRole(null, 'creator')).toBe(false)
    expect(roleLabel(op)).toBe('Super admin')
    expect(roleLabel(base)).toBe('Player')
  })
})

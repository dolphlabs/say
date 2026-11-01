import { useQuery, type QueryClient } from '@tanstack/react-query'
import { ApiError, get } from './api'

export type Role = 'creator' | 'curator' | 'treasury' | 'resolver' | 'analyst' | 'admin' | 'settler' | 'super_admin'

export type User = {
  id: string
  username: string
  email: string | null
  email_verified: boolean
  has_password: boolean
  google_linked: boolean
  username_changeable_at: string | null
  created_at?: string
  roles?: Role[]
}

export type Grant = { amount: number; season_ordinal: number; season_ends_at: string } | null

export type SignedIn = { user: User; grant: Grant }

export const PRIVATE_KEYS = ['summary', 'positions', 'orders', 'order', 'results', 'ledger', 'notifications', 'notification-prefs', 'admin', 'profile-self']

const ME = ['me'] as const

async function loadMe(): Promise<User | null> {
  try {
    return await get<User>('/v1/me')
  } catch (error) {
    if (error instanceof ApiError && error.status === 401) return null
    throw error
  }
}

export function useMe() {
  const me = useQuery({ queryKey: ME, queryFn: loadMe, retry: false, staleTime: 60_000 })
  return { ...me, user: me.data ?? null, signedIn: !!me.data }
}

function dropPrivate(client: QueryClient) {
  for (const key of PRIVATE_KEYS) client.removeQueries({ queryKey: [key] })
}

export async function installSession(client: QueryClient, user: User) {
  await client.cancelQueries({ queryKey: ME })
  dropPrivate(client)
  client.setQueryData(ME, user)
  void client.invalidateQueries({ queryKey: ME })
}

export async function endSession(client: QueryClient) {
  await client.cancelQueries()
  dropPrivate(client)
  client.setQueryData(ME, null)
}

export const hasRole = (user: User | null, ...roles: Role[]) =>
  !!user?.roles?.some((role) => roles.includes(role) || (role === 'super_admin' && roles.includes('admin')))

export const isStaff = (user: User | null) => (user?.roles?.length ?? 0) > 0

const ROLE_LABELS: Record<Role, string> = {
  super_admin: 'Super admin',
  admin: 'Admin',
  creator: 'Community creator',
  curator: 'Curator',
  treasury: 'Treasury',
  resolver: 'Resolution operator',
  analyst: 'Analyst',
  settler: 'Settlement operator',
}

const ROLE_ORDER: Role[] = ['super_admin', 'admin', 'treasury', 'resolver', 'curator', 'creator', 'settler', 'analyst']

export function roleLabel(user: User | null) {
  const top = ROLE_ORDER.find((role) => user?.roles?.includes(role))
  return top ? ROLE_LABELS[top] : 'Player'
}

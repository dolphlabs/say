import type { ReactNode } from 'react'
import { Link, useRouterState } from '@tanstack/react-router'
import { useQuery } from '@tanstack/react-query'
import { get, type Page } from '../../api'
import { hasRole, isStaff, roleLabel, useMe, type Role, type User } from '../../session'
import { Empty, Loading } from '../../ui/kit'

export type Section = 'markets' | 'sources' | 'resolution' | 'treasury' | 'approvals'

export const SECTION_ROLES: Record<Section, Role[]> = {
  markets: ['creator', 'curator', 'admin', 'super_admin'],
  sources: ['curator', 'super_admin'],
  resolution: ['resolver', 'super_admin'],
  treasury: ['treasury', 'admin', 'super_admin'],
  approvals: ['creator', 'curator', 'treasury', 'resolver', 'analyst', 'admin', 'settler', 'super_admin'],
}

const LABELS: Record<Section, string> = {
  markets: 'Markets',
  sources: 'Sources',
  resolution: 'Resolution',
  treasury: 'Treasury & bots',
  approvals: 'Approvals & audit',
}

type QueueRow = { market_id: string }
type ApprovalRow = { status: string; can_decide: boolean }

function useBadges(user: User | null) {
  const resolution = useQuery({
    queryKey: ['admin', 'resolutions', ''],
    queryFn: () => get<QueueRow[]>('/v1/admin/resolutions'),
    enabled: hasRole(user, ...SECTION_ROLES.resolution),
    refetchInterval: 30_000,
  })
  const approvals = useQuery({
    queryKey: ['admin', 'approvals'],
    queryFn: () => get<Page<ApprovalRow>>('/v1/admin/approvals'),
    enabled: isStaff(user),
    refetchInterval: 30_000,
  })
  return {
    resolution: resolution.data?.length ?? 0,
    approvals: approvals.data?.items.filter((a) => a.status === 'pending').length ?? 0,
  }
}

export function AdminShell({ section, children }: { section: Section; children: ReactNode }) {
  const { user, isLoading } = useMe()
  const badges = useBadges(user)
  const path = useRouterState({ select: (s) => s.location.pathname })
  if (isLoading) return <Loading />
  if (!user || !isStaff(user)) {
    return (
      <main className="container narrow">
        <Empty title="Staff only" action={<Link to={user ? '/' : '/login'} className="button lime">{user ? 'Back to markets' : 'Log in'}</Link>}>
          This area is for say operators.
        </Empty>
      </main>
    )
  }
  const allowed = hasRole(user, ...SECTION_ROLES[section])
  return (
    <div className="admin">
      <aside className="admin-nav" aria-label="Admin navigation">
        <Link to="/" className="admin-logo">
          <img className="logo-mark" src="/brand/svg/mark.svg" alt="" />
          <img className="logo-word" src="/brand/svg/wordmark-white.svg" alt="say" />
          <span className="admin-tag">ADMIN</span>
        </Link>
        <nav aria-label="Admin">
          {(Object.keys(LABELS) as Section[])
            .filter((s) => hasRole(user, ...SECTION_ROLES[s]))
            .map((s) => {
              const count = s === 'resolution' ? badges.resolution : s === 'approvals' ? badges.approvals : 0
              return (
                <Link key={s} to="/admin/$section" params={{ section: s }} aria-current={path === `/admin/${s}` ? 'page' : undefined}>
                  {LABELS[s]}
                  {count > 0 && <span className={`badge ${s === 'resolution' ? 'orange' : 'lime'}`}>{count}</span>}
                </Link>
              )
            })}
        </nav>
        <div className="operator">
          <span className="strong">{user.username}</span>
          <span className="muted small">{roleLabel(user)}</span>
        </div>
      </aside>
      <main className="admin-main">
        {allowed ? (
          children
        ) : (
          <Empty title={`No access to ${LABELS[section].toLowerCase()}`}>Your role doesn’t include this area. Ask a super admin if you need it.</Empty>
        )}
      </main>
    </div>
  )
}

export function AdminHeader({ title, subtitle, action }: { title: string; subtitle?: ReactNode; action?: ReactNode }) {
  return (
    <div className="admin-head">
      <div>
        <h1>{title}</h1>
        {subtitle && <span className="muted">{subtitle}</span>}
      </div>
      {action}
    </div>
  )
}

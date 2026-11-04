import { useEffect, useRef, useState, type ReactNode } from 'react'
import { Link, useNavigate, useRouterState } from '@tanstack/react-router'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { post } from './api'
import { ago, sedi } from './format'
import { isStaff, useMe } from './session'
import { BellIcon, MenuIcon, SearchIcon } from './ui/icons'
import { Avatar, Logo, Notice } from './ui/kit'
import { useNotifications, useSummary } from './features/portfolio/api'

function SearchBox() {
  const navigate = useNavigate()
  const current = useRouterState({ select: (s) => (s.location.search as { q?: string }).q ?? '' })
  const [term, setTerm] = useState(current)
  useEffect(() => setTerm(current), [current])
  return (
    <form
      role="search"
      className="search"
      onSubmit={(e) => {
        e.preventDefault()
        void navigate({ to: '/', search: { q: term.trim() || undefined } })
      }}
    >
      <SearchIcon size={16} />
      <input type="search" aria-label="Search markets" placeholder="Search say" value={term} onChange={(e) => setTerm(e.target.value)} />
    </form>
  )
}

function Notifications() {
  const [open, setOpen] = useState(false)
  const client = useQueryClient()
  const feed = useNotifications(true)
  const wrap = useRef<HTMLDivElement>(null)
  const markRead = useMutation({
    mutationFn: () => post('/v1/me/notifications/read', { all: true }),
    onSuccess: () => void client.invalidateQueries({ queryKey: ['notifications'] }),
  })
  useEffect(() => {
    if (!open) return
    const close = (e: MouseEvent | KeyboardEvent) => {
      if (e instanceof KeyboardEvent ? e.key === 'Escape' : !wrap.current?.contains(e.target as Node)) setOpen(false)
    }
    document.addEventListener('mousedown', close)
    document.addEventListener('keydown', close)
    return () => {
      document.removeEventListener('mousedown', close)
      document.removeEventListener('keydown', close)
    }
  }, [open])
  const unread = feed.data?.unread_count ?? 0
  return (
    <div className="bell-wrap" ref={wrap}>
      <button type="button" className="icon-button" aria-expanded={open} aria-label={unread ? `Notifications, ${unread} unread` : 'Notifications'} onClick={() => setOpen(!open)}>
        <BellIcon size={19} />
        {unread > 0 && <span className="dot" />}
      </button>
      {open && (
        <div className="bell-panel" role="region" aria-label="Notifications">
          <div className="bell-head">
            <strong>Notifications</strong>
            <button type="button" className="link-button" disabled={!unread || markRead.isPending} onClick={() => markRead.mutate()}>
              Mark all read
            </button>
          </div>
          {feed.error ? (
            <Notice error={feed.error} />
          ) : feed.data?.items.length ? (
            <ul>
              {feed.data.items.map((n) => (
                <li key={n.id} className={n.unread ? 'unread' : ''}>
                  <span className="dot" aria-hidden="true" />
                  <div>
                    <strong>{n.title}</strong>
                    <span>{n.body}</span>
                  </div>
                  <small>{ago(n.created_at)}</small>
                </li>
              ))}
            </ul>
          ) : (
            <p className="muted pad">{feed.isLoading ? 'Loading…' : 'Nothing yet. Fills, results and season news land here.'}</p>
          )}
          <Notice error={markRead.error} />
        </div>
      )}
    </div>
  )
}

function Account() {
  const { user } = useMe()
  const summary = useSummary(true)
  if (!user) return null
  return (
    <>
      <Link to="/portfolio" className="balance">
        <small>Balance</small>
        <b>{sedi(summary.data?.available)}</b>
      </Link>
      <Notifications />
      <Link to="/settings" className="avatar-link" aria-label="Your profile">
        <Avatar name={user.username} src={user.avatar_url} />
      </Link>
    </>
  )
}

export function Header({ children }: { children?: ReactNode }) {
  const { user, signedIn, isLoading } = useMe()
  const [menu, setMenu] = useState(false)
  const path = useRouterState({ select: (s) => s.location.pathname })
  useEffect(() => setMenu(false), [path])
  const current = (to: string) => (path === to ? 'page' : undefined)
  return (
    <header className="site-header">
      <div className="header-row">
        <Logo />
        <SearchBox />
        <button type="button" className="icon-button menu-toggle" aria-expanded={menu} aria-controls="primary-nav" aria-label="Menu" onClick={() => setMenu(!menu)}>
          <MenuIcon />
        </button>
        <nav id="primary-nav" aria-label="Primary" className={menu ? 'primary-nav open' : 'primary-nav'}>
          <Link to="/" aria-current={current('/')}>
            Markets
          </Link>
          <Link to="/portfolio" aria-current={current('/portfolio')}>
            Portfolio
          </Link>
          <Link to="/leaderboard" aria-current={current('/leaderboard')}>
            Leaderboard
          </Link>
          {isStaff(user) && <Link to="/admin/markets">Admin</Link>}
          {signedIn ? (
            <Account />
          ) : isLoading ? null : (
            <>
              <Link to="/login">Log in</Link>
              <Link to="/signup" className="button lime small">
                Sign up
              </Link>
            </>
          )}
        </nav>
      </div>
      {children}
    </header>
  )
}

export function Footer() {
  return (
    <footer className="site-footer">
      <div>
        <span>Sedis are play credits. No cash value, no withdrawals.</span>
        <nav aria-label="Footer">
          <Link to="/how-it-works">How it works</Link>
          <Link to="/how-it-works" hash="fees">
            Fees
          </Link>
          <Link to="/how-it-works" hash="resolution">
            Resolution
          </Link>
        </nav>
      </div>
    </footer>
  )
}

export function PlayerLayout({ children, header }: { children: ReactNode; header?: ReactNode }) {
  return (
    <div className="page">
      <Header>{header}</Header>
      {children}
      <Footer />
    </div>
  )
}

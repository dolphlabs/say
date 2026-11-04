import { Link, useNavigate, useParams, useRouterState } from '@tanstack/react-router'
import { isApiError } from '../../api'
import { number, ordinal, signedSedi, tone } from '../../format'
import { useMe } from '../../session'
import { PlayerLayout } from '../../shell'
import { ShareIcon } from '../../ui/icons'
import { Avatar, Empty, Loading, Notice, SidePill, Tabs } from '../../ui/kit'
import { useToast } from '../../ui/toast'
import { useSeason } from '../markets/api'
import { useProfile, type Profile, type ProfileCall } from './api'
import { Settings } from './Settings'

const STATUS: Record<string, [string, string]> = {
  WON: ['Won', 'up'],
  LOST: ['Lost', 'muted'],
  VOIDED: ['Voided · refunded', 'muted'],
}

function callStatus(c: ProfileCall) {
  if (STATUS[c.status]) return STATUS[c.status]
  if (c.chance_pct == null) return ['Open', 'soft']
  return [`Open · ${c.chance_pct}%${c.side === 'NO' ? ' for No' : ''}`, 'soft']
}

function ShareProfile({ profile }: { profile: Profile }) {
  const toast = useToast()
  const share = async () => {
    try {
      if (navigator.share) await navigator.share({ title: `@${profile.username} on say`, url: profile.share_url })
      else {
        await navigator.clipboard.writeText(profile.share_url)
        toast({ title: 'Profile link copied' })
      }
    } catch (error) {
      if (!(error instanceof DOMException && error.name === 'AbortError')) toast({ title: 'Couldn’t copy the link' })
    }
  }
  return (
    <button type="button" className="button ghost" onClick={() => void share()}>
      <ShareIcon size={16} /> Share profile
    </button>
  )
}

function ProfileBody({ profile }: { profile: Profile }) {
  const season = useSeason()
  const s = profile.current_season
  return (
    <>
      <section aria-label="Season stats" className="stat-grid">
        <div className="panel stat">
          <span>{season.data ? `Season ${ordinal(season.data.ordinal)} rank` : 'Rank'}</span>
          <strong className="display-sm">{s.rank > 0 ? `#${number(s.rank)}` : '—'}</strong>
        </div>
        <div className="panel stat">
          <span>Profit</span>
          <strong className={`display-sm ${tone(s.profit)}`}>{signedSedi(s.profit)}</strong>
        </div>
        <div className="panel stat">
          <span>Calls</span>
          <strong className="display-sm">{number(s.calls)}</strong>
        </div>
        <div className="panel stat">
          <span>Right so far</span>
          <strong className="display-sm">{s.settled ? `${s.right} of ${s.settled}` : '—'}</strong>
        </div>
      </section>
      <section className="panel calls" aria-labelledby="calls-h">
        <h2 id="calls-h">Calls</h2>
        {profile.calls.length ? (
          <ul>
            {profile.calls.map((c) => {
              const [text, cls] = callStatus(c)
              return (
                <li key={c.market.slug + c.side}>
                  <SidePill outcome={c.side} />
                  <Link to="/markets/$selector" params={{ selector: c.market.slug }} className="grow strong-link">
                    {c.market.question}
                  </Link>
                  <span className={`small strong ${cls}`}>{text}</span>
                </li>
              )
            })}
          </ul>
        ) : (
          <p className="muted">No calls yet this season.</p>
        )}
      </section>
      <p className="muted small">Anyone can see a username, rank and calls. Email and balance stay private.</p>
    </>
  )
}

export function ProfilePage() {
  const params = useParams({ strict: false }) as { username?: string }
  const path = useRouterState({ select: (s) => s.location.pathname })
  const navigate = useNavigate()
  const { user, isLoading: meLoading } = useMe()
  const settingsTab = path === '/settings'
  const username = params.username ?? user?.username
  const own = !!user && user.username.toLowerCase() === username?.toLowerCase()
  const profile = useProfile(username)

  if (!params.username && !meLoading && !user) {
    return (
      <PlayerLayout>
        <main className="container narrow">
          <Empty title="Your profile lives here" action={<Link to="/login" className="button lime">Log in</Link>}>
            Log in to see your profile and settings.
          </Empty>
        </main>
      </PlayerLayout>
    )
  }

  return (
    <PlayerLayout>
      <main className="container narrow stack">
        {(meLoading && !params.username) || profile.isLoading ? (
          <Loading />
        ) : isApiError(profile.error) && profile.error.status === 404 ? (
          <Empty title="No one by that name">Check the spelling, or they may have changed their username.</Empty>
        ) : profile.error || !profile.data ? (
          <Notice error={profile.error} />
        ) : (
          <>
            <section className="profile-head">
              <Avatar name={profile.data.username} color={profile.data.avatar_color} src={profile.data.avatar_url} size="xl" />
              <div className="grow">
                <h1>@{profile.data.username}</h1>
                {profile.data.joined_season && <span className="muted">Playing since {profile.data.joined_season}</span>}
              </div>
              <ShareProfile profile={profile.data} />
            </section>
            {own && (
              <Tabs
                label="Profile sections"
                value={settingsTab ? 'settings' : 'profile'}
                onChange={(t) => void navigate(t === 'settings' ? { to: '/settings' } : { to: '/users/$username', params: { username: profile.data!.username } })}
                tabs={[
                  { key: 'profile', label: 'Profile' },
                  { key: 'settings', label: 'Settings' },
                ]}
              />
            )}
            {own && settingsTab && user ? <Settings user={user} /> : <ProfileBody profile={profile.data} />}
          </>
        )}
      </main>
    </PlayerLayout>
  )
}

import { useRef, useState, type ChangeEvent, type FormEvent, type ReactNode } from 'react'
import { useNavigate, useSearch } from '@tanstack/react-router'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { errorMessage, isApiError, post, send } from '../../api'
import { dateTime } from '../../format'
import { endSession, isStaff, type User } from '../../session'
import { Avatar, Chip, Notice } from '../../ui/kit'
import { holdUsername, normalizeUsername, USERNAME_PATTERN } from '../auth/api'
import { usePreferences, type Preference } from './api'

function Row({ label, value, children }: { label: string; value: ReactNode; children?: ReactNode }) {
  return (
    <div className="setting-row">
      <div className="grow">
        <div className="muted small">{label}</div>
        <div className="strong">{value}</div>
      </div>
      {children}
    </div>
  )
}

const PHOTO_TYPES = ['image/jpeg', 'image/png', 'image/webp']
const PHOTO_MAX_BYTES = 5 * 1024 * 1024

type UploadTicket = { upload_url: string; fields: Record<string, string> }
type Uploaded = { public_id: string; version: number | string; signature: string }

export async function uploadPhoto(file: File): Promise<string> {
  if (!PHOTO_TYPES.includes(file.type)) throw new Error('Use a JPG, PNG or WebP image.')
  if (file.size > PHOTO_MAX_BYTES) throw new Error('Use an image under 5 MB.')
  const ticket = await post<UploadTicket>('/v1/me/avatar/upload')
  const form = new FormData()
  for (const [key, value] of Object.entries(ticket.fields)) form.append(key, value)
  form.append('file', file)
  const res = await fetch(ticket.upload_url, { method: 'POST', body: form })
  const body = (await res.json().catch(() => null)) as (Uploaded & { error?: { message?: string } }) | null
  if (!res.ok || !body) throw new Error(body?.error?.message ?? 'The photo could not be uploaded. Try again.')
  const saved = await send<{ avatar_url: string }>('PUT', '/v1/me/avatar', {
    public_id: body.public_id,
    version: String(body.version),
    signature: body.signature,
  })
  return saved.avatar_url
}

function PhotoRow({ user }: { user: User }) {
  const client = useQueryClient()
  const input = useRef<HTMLInputElement>(null)
  const refresh = () => Promise.all(['me', 'profile', 'leaderboard'].map((key) => client.invalidateQueries({ queryKey: [key] })))
  const upload = useMutation({ mutationFn: uploadPhoto, onSuccess: refresh })
  const remove = useMutation({ mutationFn: () => send('DELETE', '/v1/me/avatar'), onSuccess: refresh })
  const pick = (e: ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0]
    e.target.value = ''
    if (file) upload.mutate(file)
  }
  const busy = upload.isPending || remove.isPending
  return (
    <>
      <div className="setting-row">
        <Avatar name={user.username} src={user.avatar_url} size="lg" />
        <div className="grow">
          <div className="muted small">Profile photo</div>
          <div className="strong">{upload.isPending ? 'Uploading…' : user.avatar_url ? 'Shown on your profile and the leaderboard' : 'No photo yet'}</div>
        </div>
        <input ref={input} type="file" accept={PHOTO_TYPES.join(',')} hidden onChange={pick} aria-label="Choose a profile photo" />
        <button type="button" className="button ghost small" disabled={busy} onClick={() => input.current?.click()}>
          {user.avatar_url ? 'Change' : 'Upload'}
        </button>
        {user.avatar_url && (
          <button type="button" className="button ghost small" disabled={busy} onClick={() => remove.mutate()}>
            Remove
          </button>
        )}
      </div>
      <Notice error={upload.error ?? remove.error} />
    </>
  )
}

function UsernameRow({ user }: { user: User }) {
  const client = useQueryClient()
  const [open, setOpen] = useState(false)
  const [name, setName] = useState('')
  const changeable = !user.username_changeable_at || new Date(user.username_changeable_at).getTime() <= Date.now()
  const change = useMutation({
    mutationFn: async () => {
      const held = await holdUsername(name)
      await post('/v1/me/username', { username: held.username, hold_id: held.hold_id })
    },
    onSuccess: () => {
      setOpen(false)
      setName('')
      void client.invalidateQueries({ queryKey: ['me'] })
    },
  })
  return (
    <>
      <Row label="Username" value={`@${user.username}`}>
        {changeable ? (
          <button type="button" className="button ghost small" aria-expanded={open} onClick={() => setOpen(!open)}>
            {open ? 'Cancel' : 'Change'}
          </button>
        ) : (
          <span className="muted small">You can change it after {dateTime(user.username_changeable_at)}.</span>
        )}
      </Row>
      {open && (
        <form
          className="setting-form"
          onSubmit={(e) => {
            e.preventDefault()
            change.mutate()
          }}
        >
          <label>
            New username
            <input value={name} onChange={(e) => setName(normalizeUsername(e.target.value))} autoCapitalize="none" spellCheck={false} maxLength={20} placeholder="yourname" />
          </label>
          <p className="muted small">3–20 characters: letters, numbers, dots and underscores. It stays fixed until the season ends.</p>
          <Notice error={change.error} />
          <button type="submit" className="button lime" disabled={!USERNAME_PATTERN.test(name) || change.isPending}>
            {change.isPending ? 'Saving…' : 'Save username'}
          </button>
        </form>
      )}
    </>
  )
}

function EmailRow({ user }: { user: User }) {
  const client = useQueryClient()
  const [open, setOpen] = useState(false)
  const [email, setEmail] = useState('')
  const [token, setToken] = useState('')
  const [code, setCode] = useState('')
  const request = useMutation({ mutationFn: () => post<{ change_token: string }>('/v1/me/email', { new_email: email }), onSuccess: (r) => setToken(r.change_token) })
  const verify = useMutation({
    mutationFn: () => post('/v1/me/email/verify', { change_token: token, code }),
    onSuccess: () => {
      setOpen(false)
      setToken('')
      setCode('')
      setEmail('')
      void client.invalidateQueries({ queryKey: ['me'] })
    },
  })
  return (
    <>
      <Row
        label="Email"
        value={
          <span className="row tight">
            {user.email ?? 'No email'}
            {user.email_verified && <Chip tone="green">Verified</Chip>}
          </span>
        }
      >
        <button type="button" className="button ghost small" aria-expanded={open} onClick={() => setOpen(!open)}>
          {open ? 'Cancel' : 'Change'}
        </button>
      </Row>
      {open &&
        (!token ? (
          <form
            className="setting-form"
            onSubmit={(e) => {
              e.preventDefault()
              request.mutate()
            }}
          >
            <label>
              New email
              <input type="email" autoComplete="email" value={email} onChange={(e) => setEmail(e.target.value.trim())} required />
            </label>
            <Notice error={request.error} />
            <button type="submit" className="button lime" disabled={!email || request.isPending}>
              {request.isPending ? 'Sending…' : 'Send a code'}
            </button>
          </form>
        ) : (
          <form
            className="setting-form"
            onSubmit={(e) => {
              e.preventDefault()
              verify.mutate()
            }}
          >
            <label>
              Code sent to {email}
              <input inputMode="numeric" autoComplete="one-time-code" maxLength={6} value={code} onChange={(e) => setCode(e.target.value.replace(/\D/g, ''))} required />
            </label>
            <Notice error={verify.error} />
            <button type="submit" className="button lime" disabled={code.length !== 6 || verify.isPending}>
              {verify.isPending ? 'Checking…' : 'Confirm new email'}
            </button>
          </form>
        ))}
    </>
  )
}

function PasswordRow({ user }: { user: User }) {
  const [open, setOpen] = useState(false)
  const [current, setCurrent] = useState('')
  const [next, setNext] = useState('')
  const [saved, setSaved] = useState(false)
  const change = useMutation({
    mutationFn: () => post('/v1/me/password', { current_password: current, new_password: next }),
    onSuccess: () => {
      setCurrent('')
      setNext('')
      setOpen(false)
      setSaved(true)
    },
  })
  const submit = (e: FormEvent) => {
    e.preventDefault()
    setSaved(false)
    change.mutate()
  }
  if (!user.has_password) return <Row label="Password" value="Not set · you sign in with Google" />
  return (
    <>
      <Row label="Password" value={saved ? 'Changed · other sessions signed out' : 'Set'}>
        <button type="button" className="button ghost small" aria-expanded={open} onClick={() => setOpen(!open)}>
          {open ? 'Cancel' : 'Change password'}
        </button>
      </Row>
      {open && (
        <form className="setting-form" onSubmit={submit}>
          <label>
            Current password
            <input type="password" autoComplete="current-password" value={current} onChange={(e) => setCurrent(e.target.value)} required />
          </label>
          <label>
            New password
            <input type="password" autoComplete="new-password" placeholder="8 characters or more" minLength={8} maxLength={128} value={next} onChange={(e) => setNext(e.target.value)} required />
          </label>
          <Notice error={change.error} />
          <button type="submit" className="button lime" disabled={!current || next.length < 8 || change.isPending}>
            {change.isPending ? 'Saving…' : 'Save password'}
          </button>
        </form>
      )}
    </>
  )
}

function GoogleRow({ user }: { user: User }) {
  const client = useQueryClient()
  const linked = useSearch({ strict: false, select: (s: { google?: string }) => s.google === 'linked' })
  const unlink = useMutation({ mutationFn: () => send('DELETE', '/v1/me/google'), onSuccess: () => void client.invalidateQueries({ queryKey: ['me'] }) })
  return (
    <>
      <div className="setting-row">
        <span className="g-avatar" aria-hidden="true">
          G
        </span>
        <div className="grow">
          <div className="muted small">Google</div>
          <div className="strong">{user.google_linked ? 'Linked' : 'Not linked'}</div>
        </div>
        {user.google_linked ? (
          <button type="button" className="button ghost small" disabled={unlink.isPending} onClick={() => unlink.mutate()}>
            Unlink
          </button>
        ) : (
          <a href="/v1/auth/google/start?intent=link" className="button ghost small">
            Link Google
          </a>
        )}
      </div>
      {linked && user.google_linked && (
        <p className="success" role="status">
          Google is linked. You can sign in with either.
        </p>
      )}
      {isApiError(unlink.error, 'LAST_SIGN_IN_METHOD') ? <Notice>Set a password before unlinking Google, or you won’t be able to sign in.</Notice> : <Notice error={unlink.error} />}
    </>
  )
}

function Switch({ label, on, disabled, onChange }: { label: string; on: boolean; disabled?: boolean; onChange: (on: boolean) => void }) {
  return (
    <button type="button" role="switch" aria-checked={on} aria-label={label} disabled={disabled} className="switch" onClick={() => onChange(!on)}>
      <span />
    </button>
  )
}

function Notifications() {
  const client = useQueryClient()
  const prefs = usePreferences()
  const update = useMutation({
    mutationFn: (p: Preference) => send('PUT', '/v1/me/notification-prefs', { kind: p.kind, in_app: p.in_app, email: p.email }),
    onMutate: async (p) => {
      await client.cancelQueries({ queryKey: ['notification-prefs'] })
      const previous = client.getQueryData<Preference[]>(['notification-prefs'])
      client.setQueryData<Preference[]>(['notification-prefs'], (list) => list?.map((x) => (x.kind === p.kind ? p : x)))
      return { previous }
    },
    onError: (_e, _p, ctx) => client.setQueryData(['notification-prefs'], ctx?.previous),
    onSettled: () => void client.invalidateQueries({ queryKey: ['notification-prefs'] }),
  })
  return (
    <section className="panel settings-card" aria-labelledby="notif-h">
      <h2 id="notif-h">Notifications</h2>
      {prefs.error && <Notice error={prefs.error} />}
      {prefs.data?.length ? (
        <>
          <div className="pref-head" aria-hidden="true">
            <span />
            <span>In app</span>
            <span>Email</span>
          </div>
          {prefs.data.map((p) => (
            <div className="pref-row" key={p.kind}>
              <div className="grow">
                <div className="strong">{p.label}</div>
                <div className="muted small">{p.hint}</div>
              </div>
              <Switch label={`${p.label} in app`} on={p.in_app} disabled={update.isPending} onChange={(v) => update.mutate({ ...p, in_app: v })} />
              <Switch label={`${p.label} by email`} on={p.email} disabled={update.isPending} onChange={(v) => update.mutate({ ...p, email: v })} />
            </div>
          ))}
        </>
      ) : (
        !prefs.error && <p className="muted">{prefs.isLoading ? 'Loading…' : 'No notification settings yet.'}</p>
      )}
      <Notice error={update.error} />
    </section>
  )
}

function TwoFactor() {
  const [secret, setSecret] = useState<{ secret: string; uri: string } | null>(null)
  const [code, setCode] = useState('')
  const [done, setDone] = useState('')
  const enroll = useMutation({ mutationFn: () => post<{ secret: string; uri: string }>('/v1/me/2fa/enroll', {}), onSuccess: setSecret })
  const verify = useMutation({
    mutationFn: () => post('/v1/me/2fa/verify', { code }),
    onSuccess: () => {
      setCode('')
      setSecret(null)
      setDone('Verified. Staff approvals are unlocked for this session.')
    },
  })
  const disable = useMutation({
    mutationFn: () => post('/v1/me/2fa/disable', { code }),
    onSuccess: () => {
      setCode('')
      setDone('Authenticator removed.')
    },
  })
  return (
    <section className="panel settings-card" aria-labelledby="tfa-h">
      <h2 id="tfa-h">Authenticator</h2>
      <p className="muted small">Approvals and other staff decisions need a code from your authenticator app, checked in this session.</p>
      {secret && (
        <div className="secret-box">
          <span className="muted small">Add this key to your authenticator app, then enter the code it shows.</span>
          <code>{secret.secret}</code>
          <a href={secret.uri} className="muted-link small">
            Open in authenticator
          </a>
        </div>
      )}
      <form
        className="setting-form inline"
        onSubmit={(e) => {
          e.preventDefault()
          setDone('')
          verify.mutate()
        }}
      >
        <label>
          Code
          <input inputMode="numeric" autoComplete="one-time-code" maxLength={6} value={code} onChange={(e) => setCode(e.target.value.replace(/\D/g, ''))} />
        </label>
        <button type="submit" className="button lime" disabled={code.length !== 6 || verify.isPending}>
          Verify code
        </button>
        <button type="button" className="button ghost" disabled={enroll.isPending} onClick={() => enroll.mutate()}>
          Set up authenticator
        </button>
        <button type="button" className="button ghost danger-text" disabled={code.length !== 6 || disable.isPending} onClick={() => disable.mutate()}>
          Remove
        </button>
      </form>
      {done && (
        <p className="success" role="status">
          {done}
        </p>
      )}
      <Notice error={enroll.error ?? verify.error ?? disable.error} />
    </section>
  )
}

function DeleteAccount({ user }: { user: User }) {
  const client = useQueryClient()
  const navigate = useNavigate()
  const [open, setOpen] = useState(false)
  const [typed, setTyped] = useState('')
  const remove = useMutation({
    mutationFn: () => send('DELETE', '/v1/me'),
    onSuccess: async () => {
      await endSession(client)
      void navigate({ to: '/' })
    },
  })
  const confirmed = typed.trim().toLowerCase() === user.username.toLowerCase()
  return (
    <div className="setting-row danger-zone">
      <div className="grow">
        <div className="strong danger-text">Delete account</div>
        <div className="muted small">
          Signs you out everywhere and cancels your open orders. Your username, email, photo and sign-in details are then removed for good. Past trades stay in the records without your name.
        </div>
        {open && (
          <form
            className="stack small-gap"
            onSubmit={(e: FormEvent) => {
              e.preventDefault()
              if (confirmed) remove.mutate()
            }}
          >
            <label htmlFor="delete-confirm" className="small">
              Type <strong>{user.username}</strong> to confirm
            </label>
            <input id="delete-confirm" className="input" autoComplete="off" value={typed} onChange={(e: ChangeEvent<HTMLInputElement>) => setTyped(e.target.value)} />
            <div className="row wrap">
              <button type="submit" className="button outline-red small" disabled={!confirmed || remove.isPending}>
                Delete my account
              </button>
              <button type="button" className="button ghost small" onClick={() => { setOpen(false); setTyped('') }}>
                Keep my account
              </button>
            </div>
            <Notice error={remove.error ? errorMessage(remove.error) : undefined} />
          </form>
        )}
      </div>
      {!open && (
        <button type="button" className="button outline-red small" onClick={() => setOpen(true)}>
          Delete account
        </button>
      )}
    </div>
  )
}

function SignOut({ user }: { user: User }) {
  const client = useQueryClient()
  const navigate = useNavigate()
  const [others, setOthers] = useState(false)
  const logout = useMutation({
    mutationFn: () => post('/v1/auth/logout', {}),
    onSettled: async () => {
      await endSession(client)
      void navigate({ to: '/login' })
    },
  })
  const logoutOthers = useMutation({ mutationFn: () => post('/v1/auth/logout-others', {}), onSuccess: () => setOthers(true) })
  return (
    <section className="panel settings-card" aria-labelledby="out-h">
      <h2 id="out-h">Sign out</h2>
      <div className="row wrap">
        <button type="button" className="button dim" disabled={logout.isPending} onClick={() => logout.mutate()}>
          Log out
        </button>
        <button type="button" className="button ghost" disabled={logoutOthers.isPending} onClick={() => logoutOthers.mutate()}>
          Log out everywhere else
        </button>
      </div>
      {others && (
        <p className="success" role="status">
          Every other session is signed out.
        </p>
      )}
      <Notice error={logoutOthers.error ? errorMessage(logoutOthers.error) : undefined} />
      <DeleteAccount user={user} />
    </section>
  )
}

export function Settings({ user }: { user: User }) {
  return (
    <div className="stack">
      <section className="panel settings-card" aria-labelledby="acct-h">
        <h2 id="acct-h">Account</h2>
        <PhotoRow user={user} />
        <UsernameRow user={user} />
        <EmailRow user={user} />
        <PasswordRow user={user} />
        <GoogleRow user={user} />
      </section>
      <Notifications />
      {isStaff(user) && <TwoFactor />}
      <SignOut user={user} />
    </div>
  )
}

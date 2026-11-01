import { useEffect, useState, type FormEvent } from 'react'
import { Link, useNavigate, useSearch } from '@tanstack/react-router'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { errorMessage, isApiError } from '../../api'
import { dateTime, ordinal, sedi } from '../../format'
import { installSession, type Grant, type User } from '../../session'
import { CheckIcon } from '../../ui/icons'
import { Notice } from '../../ui/kit'
import { useSeason } from '../markets/api'
import { authMessage, checkUsername, completeGoogle, holdUsername, normalizeUsername, resendCode, signup, USERNAME_PATTERN, verifyCode, type Signup as SignupResult } from './api'
import { AuthLayout, CodeInput, Divider, GoogleButton, PasswordInput, StrengthMeter, useResendTimer } from './parts'

function useDebounced<T>(value: T, ms: number) {
  const [settled, setSettled] = useState(value)
  useEffect(() => {
    const id = setTimeout(() => setSettled(value), ms)
    return () => clearTimeout(id)
  }, [value, ms])
  return settled
}

export function UsernameStep({ google, onHeld }: { google?: { email: string }; onHeld: (username: string, holdId: string) => Promise<void> | void }) {
  const [name, setName] = useState('')
  const settled = useDebounced(name, 300)
  const valid = USERNAME_PATTERN.test(settled)
  const check = useQuery({ queryKey: ['username', settled], queryFn: () => checkUsername(settled), enabled: valid, staleTime: 30_000, retry: false })
  const hold = useMutation({
    mutationFn: async () => {
      const held = await holdUsername(name)
      await onHeld(held.username, held.hold_id)
    },
  })
  const fresh = settled === name
  const result = fresh && valid ? check.data : undefined
  const ok = !!result?.available
  const taken = !!result && !result.available

  let message = 'Pick something people will remember.'
  let tone = ''
  if (name.length > 0 && name.length < 3) message = 'A little longer. At least 3 characters.'
  else if (name.length >= 3 && !USERNAME_PATTERN.test(name)) [message, tone] = ['Can’t start with a dot or underscore, or end with a dot.', 'warn']
  else if (fresh && check.isFetching) message = `Checking @${name}…`
  else if (result?.reason === 'USERNAME_RESERVED') [message, tone] = [`@${name} is reserved. Try one of these:`, 'bad']
  else if (taken) [message, tone] = [`@${name} is taken. Try one of these:`, 'bad']
  else if (ok) [message, tone] = [`@${name} is available.`, 'good']
  else if (check.error && fresh) [message, tone] = [errorMessage(check.error), 'warn']

  const submit = (e: FormEvent) => {
    e.preventDefault()
    if (ok) hold.mutate()
  }
  const cta = google ? `Claim @${ok ? name : '…'} and start` : 'Continue'

  return (
    <form className="auth-form" onSubmit={submit}>
      {google && (
        <div className="connected">
          <span className="g-mark" aria-hidden="true">
            G
          </span>
          <span>
            Google connected · <span className="muted">{google.email}</span>
          </span>
          <CheckIcon size={16} />
        </div>
      )}
      <div className="auth-intro">
        <h1>What should we call you?</h1>
        <p>This is how you show up on the leaderboard. You can’t change it mid-season.</p>
      </div>
      <div className="field">
        <label htmlFor="uname">Username</label>
        <div className={`field-box ${ok ? 'good' : taken ? 'bad' : ''}`}>
          <span aria-hidden="true" className="at">
            @
          </span>
          <input id="uname" value={name} onChange={(e) => setName(normalizeUsername(e.target.value))} autoComplete="username" autoCapitalize="none" spellCheck={false} maxLength={20} placeholder="yourname" />
          {ok && <CheckIcon size={18} className="good" />}
        </div>
        <p className={`field-note ${tone}`} role="status">
          {message}
        </p>
        {taken && !!result?.suggestions.length && (
          <div className="suggestions">
            {result.suggestions.map((s) => (
              <button type="button" key={s} onClick={() => setName(s)}>
                @{s}
              </button>
            ))}
          </div>
        )}
      </div>
      <Notice error={hold.error && authMessage(isApiError(hold.error) ? hold.error.code : undefined, errorMessage(hold.error))} />
      <div className="auth-foot">
        <button type="submit" className="cta lime" disabled={!ok || hold.isPending}>
          {hold.isPending ? 'Holding your name…' : cta}
        </button>
        <p className="muted small center">3–20 characters: letters, numbers, dots and underscores.</p>
      </div>
    </form>
  )
}

function CredentialsStep({ username, holdId, onSent, onRestart }: { username: string; holdId: string; onSent: (r: SignupResult, email: string) => void; onRestart: () => void }) {
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const send = useMutation({ mutationFn: () => signup({ username, hold_id: holdId, email, password }), onSuccess: (r) => onSent(r, email) })
  const emailOk = /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)
  const ok = emailOk && password.length >= 8
  const holdLost = isApiError(send.error, 'USERNAME_TAKEN', 'USERNAME_HOLD_EXPIRED')
  return (
    <form
      className="auth-form"
      onSubmit={(e) => {
        e.preventDefault()
        if (ok) send.mutate()
      }}
    >
      <div className="auth-intro">
        <span className="handle-chip">@{username}</span>
        <h1>Now lock it in.</h1>
        <p>Just an email and a password. We’ll send a code to make sure it’s you.</p>
      </div>
      <div className="field">
        <label htmlFor="email">Email</label>
        <div className="field-box">
          <input id="email" type="email" value={email} onChange={(e) => setEmail(e.target.value.trim())} autoComplete="email" placeholder="you@example.com" required />
        </div>
        {email.length > 3 && !emailOk && (
          <p className="field-note warn" role="status">
            That doesn’t look like an email yet.
          </p>
        )}
      </div>
      <div className="field">
        <label htmlFor="pw">Password</label>
        <PasswordInput id="pw" value={password} onChange={setPassword} autoComplete="new-password" placeholder="8 characters or more" />
        <StrengthMeter password={password} />
      </div>
      {holdLost ? (
        <Notice>
          Your hold on @{username} ran out.{' '}
          <button type="button" className="link-button" onClick={onRestart}>
            Pick a username again
          </button>
        </Notice>
      ) : isApiError(send.error, 'EMAIL_IN_USE') ? (
        <Notice>
          That email already has an account. <Link to="/login">Log in instead</Link>
        </Notice>
      ) : (
        <Notice error={send.error} />
      )}
      <div className="auth-foot">
        <button type="submit" className="cta lime" disabled={!ok || send.isPending}>
          {send.isPending ? 'Sending…' : 'Send my code'}
        </button>
        <p className="muted small center">No ID, no bank details. Ever. It’s play money.</p>
      </div>
    </form>
  )
}

export function VerifyStep({ token, masked, resendAt, onVerified, onBack }: { token: string; masked: string; resendAt: string | null; onVerified: (user: User, grant: Grant) => void; onBack?: () => void }) {
  const [code, setCode] = useState('')
  const [nextResend, setNextResend] = useState(resendAt)
  const timer = useResendTimer(nextResend)
  const verify = useMutation({ mutationFn: () => verifyCode(token, code), onSuccess: (r) => onVerified(r.user, r.grant) })
  const resend = useMutation({ mutationFn: () => resendCode(token), onSuccess: (r) => setNextResend(r.resend_available_at) })
  const failure = verify.error
  const wrong = isApiError(failure, 'OTP_INVALID')
  const left = isApiError(failure, 'OTP_INVALID') ? failure.details.attempts_left : undefined
  const attempts = typeof left === 'number' ? left : null
  const edit = (next: string) => {
    setCode(next)
    if (verify.error) verify.reset()
  }
  return (
    <form
      className="auth-form"
      onSubmit={(e) => {
        e.preventDefault()
        if (code.length === 6) verify.mutate()
      }}
    >
      <div className="auth-intro">
        <h1>Check your inbox.</h1>
        <p>
          We sent a 6-digit code to <strong>{masked}</strong>.{' '}
          {onBack && (
            <button type="button" className="link-button" onClick={onBack}>
              Wrong email?
            </button>
          )}
        </p>
      </div>
      <div className="field">
        <label htmlFor="code">Verification code</label>
        <CodeInput value={code} onChange={edit} invalid={wrong} />
        {wrong ? (
          <p className="field-note bad" role="status">
            That code didn’t match.{attempts != null && ` ${attempts === 0 ? 'One more wrong try locks it.' : `${attempts} tries left.`}`}
          </p>
        ) : isApiError(verify.error, 'OTP_EXPIRED', 'OTP_LOCKED') ? (
          <p className="field-note bad" role="status">
            That code has run out. Send a new one.
          </p>
        ) : (
          <Notice error={verify.error} />
        )}
        <p className="muted small">
          Didn’t get it? Check spam, or{' '}
          {timer.wait > 0 ? (
            <span>resend in {timer.label}</span>
          ) : (
            <button type="button" className="link-button" disabled={resend.isPending} onClick={() => resend.mutate()}>
              send a new code
            </button>
          )}
          {resend.isSuccess && timer.wait > 0 && ' · sent'}
        </p>
        <Notice error={resend.error} />
      </div>
      <div className="auth-foot">
        <button type="submit" className="cta lime" disabled={code.length < 6 || verify.isPending}>
          {verify.isPending ? 'Checking…' : 'Verify and start playing'}
        </button>
        <p className="muted small center">Codes expire after 10 minutes.</p>
      </div>
    </form>
  )
}

export function Welcome({ username, grant }: { username: string; grant: Grant }) {
  return (
    <div className="auth-form">
      <div className="grant-card">
        <span className="spark a" aria-hidden="true" />
        <span className="spark b" aria-hidden="true" />
        <span className="spark c" aria-hidden="true" />
        {grant ? (
          <>
            <span>Added to your balance</span>
            <strong>{sedi(grant.amount)}</strong>
            <span>
              Season {ordinal(grant.season_ordinal)} · ends {dateTime(grant.season_ends_at)}
            </span>
          </>
        ) : (
          <>
            <span>You’re verified</span>
            <strong>Next season</strong>
            <span>Your starting balance lands when it opens.</span>
          </>
        )}
      </div>
      <div className="auth-intro">
        <h1>You’re in, @{username}.</h1>
        <p>Pick a side on anything that’s live. Every season the board resets and everyone starts level again.</p>
      </div>
      <div className="auth-foot">
        <Link to="/" className="cta lime">
          Start playing
        </Link>
        <Link to="/how-it-works" className="cta ghost">
          How does this work?
        </Link>
      </div>
    </div>
  )
}

type Step =
  | { name: 'choose' }
  | { name: 'username' }
  | { name: 'credentials'; username: string; holdId: string }
  | { name: 'verify'; username: string; token: string; masked: string; resendAt: string | null; holdId: string }
  | { name: 'done'; username: string; grant: Grant }

export function SignupPage() {
  const client = useQueryClient()
  const season = useSeason()
  const [step, setStep] = useState<Step>({ name: 'choose' })
  const done = async (user: User, grant: Grant) => {
    await installSession(client, user)
    setStep({ name: 'done', username: user.username, grant })
  }
  return (
    <AuthLayout aside={{ to: '/login', label: 'Log in' }}>
      {step.name === 'choose' && (
        <div className="auth-form">
          <div className="auth-intro">
            {season.data && (
              <span className="season-pill">
                <span className="dot" aria-hidden="true" />
                Season {ordinal(season.data.ordinal)} is live
              </span>
            )}
            <h1 className="hero-title">
              Get <span className="lime-text">free sedis</span> to play with.
            </h1>
            <p>Call it on football, music, tech and whatever the timeline is arguing about. No real money, no ID.</p>
          </div>
          <div className="stack-tight">
            <GoogleButton intent="signup" />
            <Divider>or</Divider>
            <button type="button" className="cta dark" onClick={() => setStep({ name: 'username' })}>
              Sign up with email
            </button>
          </div>
          <p className="muted small center">
            Already playing? <Link to="/login">Log in</Link>
          </p>
          <p className="muted tiny center">
            By joining you agree to the <Link to="/how-it-works">Rules</Link>. Sedis have no cash value.
          </p>
        </div>
      )}
      {step.name === 'username' && <UsernameStep onHeld={(username, holdId) => setStep({ name: 'credentials', username, holdId })} />}
      {step.name === 'credentials' && (
        <CredentialsStep
          username={step.username}
          holdId={step.holdId}
          onRestart={() => setStep({ name: 'username' })}
          onSent={(r) => setStep({ name: 'verify', username: step.username, holdId: step.holdId, token: r.signup_token, masked: r.email_masked, resendAt: r.resend_available_at })}
        />
      )}
      {step.name === 'verify' && (
        <VerifyStep token={step.token} masked={step.masked} resendAt={step.resendAt} onVerified={done} onBack={() => setStep({ name: 'credentials', username: step.username, holdId: step.holdId })} />
      )}
      {step.name === 'done' && <Welcome username={step.username} grant={step.grant} />}
    </AuthLayout>
  )
}

export function GoogleSignupPage() {
  const client = useQueryClient()
  const navigate = useNavigate()
  const search = useSearch({ from: '/signup/google' })
  const [pending] = useState(() => ({ token: search.pending_token ?? '', email: search.email ?? '' }))
  const [finished, setFinished] = useState<{ username: string; grant: Grant } | null>(null)
  const [failure, setFailure] = useState<unknown>(null)

  useEffect(() => {
    if (search.pending_token) void navigate({ to: '/signup/google', search: {}, replace: true })
  }, [search.pending_token, navigate])

  if (!pending.token) {
    return (
      <AuthLayout aside={{ to: '/login', label: 'Log in' }}>
        <div className="auth-form">
          <Notice>Google sign-up has expired. Start again.</Notice>
          <GoogleButton intent="signup" />
        </div>
      </AuthLayout>
    )
  }

  return (
    <AuthLayout aside={{ to: '/login', label: 'Log in' }}>
      {finished ? (
        <Welcome username={finished.username} grant={finished.grant} />
      ) : (
        <>
          <UsernameStep
            google={{ email: pending.email }}
            onHeld={async (username, holdId) => {
              try {
                const r = await completeGoogle({ pending_token: pending.token, username, hold_id: holdId })
                await installSession(client, r.user)
                setFinished({ username: r.user.username, grant: r.grant })
              } catch (error) {
                setFailure(error)
              }
            }}
          />
          {!!failure && (
            <div className="auth-form">
              <Notice>{authMessage(isApiError(failure) ? failure.code : undefined, errorMessage(failure))}</Notice>
              {isApiError(failure, 'PENDING_EXPIRED') && <GoogleButton intent="signup" />}
            </div>
          )}
        </>
      )}
    </AuthLayout>
  )
}

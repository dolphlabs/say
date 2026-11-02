import { useState, type FormEvent } from 'react'
import { Link, useNavigate, useSearch } from '@tanstack/react-router'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { ApiError, errorMessage, isApiError } from '../../api'
import { installSession, type Grant, type User } from '../../session'
import { Notice } from '../../ui/kit'
import { authMessage, forgotPassword, login, resetPassword } from './api'
import { AuthLayout, CodeInput, Divider, GoogleButton, PasswordInput, StrengthMeter } from './parts'
import { VerifyStep, Welcome } from './Signup'

type Step = { name: 'login' } | { name: 'forgot' } | { name: 'reset'; email: string } | { name: 'verify'; token: string; masked: string } | { name: 'done'; username: string; grant: Grant }

function ResetForm({ email, onDone }: { email: string; onDone: () => void }) {
  const [code, setCode] = useState('')
  const [password, setPassword] = useState('')
  const reset = useMutation({ mutationFn: () => resetPassword(email, code, password), onSuccess: onDone })
  return (
    <form
      className="auth-form"
      onSubmit={(e) => {
        e.preventDefault()
        reset.mutate()
      }}
    >
      <div className="auth-intro">
        <h1>Choose a new password.</h1>
        <p>If an account exists for {email}, a 6-digit code is on its way.</p>
      </div>
      <div className="field">
        <label htmlFor="code">Code</label>
        <CodeInput value={code} onChange={setCode} invalid={isApiError(reset.error, 'OTP_INVALID')} />
      </div>
      <div className="field">
        <label htmlFor="new-pw">New password</label>
        <PasswordInput id="new-pw" value={password} onChange={setPassword} autoComplete="new-password" placeholder="8 characters or more" />
        <StrengthMeter password={password} />
      </div>
      <Notice error={reset.error} />
      <button type="submit" className="cta lime" disabled={code.length < 6 || password.length < 8 || reset.isPending}>
        {reset.isPending ? 'Saving…' : 'Save new password'}
      </button>
    </form>
  )
}

export function LoginPage() {
  const client = useQueryClient()
  const navigate = useNavigate()
  const search = useSearch({ from: '/login' })
  const [step, setStep] = useState<Step>({ name: 'login' })
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [resetDone, setResetDone] = useState(false)

  const signIn = useMutation({
    mutationFn: () => login(email, password),
    onSuccess: async (r) => {
      setPassword('')
      await installSession(client, r.user)
      void navigate({ to: '/' })
    },
    onError: (error) => {
      if (error instanceof ApiError && error.code === 'EMAIL_NOT_VERIFIED' && typeof error.details.signup_token === 'string') {
        setPassword('')
        setStep({ name: 'verify', token: error.details.signup_token, masked: email })
      }
    },
  })
  const forgot = useMutation({ mutationFn: () => forgotPassword(email), onSuccess: () => setStep({ name: 'reset', email }) })

  const verified = async (user: User, grant: Grant) => {
    await installSession(client, user)
    setStep({ name: 'done', username: user.username, grant })
  }

  const submit = (e: FormEvent) => {
    e.preventDefault()
    setResetDone(false)
    signIn.mutate()
  }

  return (
    <AuthLayout aside={{ to: '/signup', label: 'Sign up' }}>
      {step.name === 'login' && (
        <form className="auth-form" onSubmit={submit}>
          <h1>Welcome back.</h1>
          {search.error && <Notice>{authMessage(search.error, 'Google sign-in didn’t work. Try again.')}</Notice>}
          {resetDone && (
            <p className="success" role="status">
              Password saved. Log in with the new one.
            </p>
          )}
          <GoogleButton intent="login" />
          <Divider>or with email</Divider>
          <div className="field">
            <label htmlFor="l-email">Email</label>
            <div className="field-box">
              <input id="l-email" type="email" autoComplete="email" placeholder="you@example.com" value={email} onChange={(e) => setEmail(e.target.value.trim())} required />
            </div>
          </div>
          <div className="field">
            <div className="label-row">
              <label htmlFor="l-pw">Password</label>
              <button type="button" className="link-button" onClick={() => setStep({ name: 'forgot' })}>
                Forgot it?
              </button>
            </div>
            <PasswordInput id="l-pw" value={password} onChange={setPassword} autoComplete="current-password" />
          </div>
          {signIn.error && !isApiError(signIn.error, 'EMAIL_NOT_VERIFIED') && <Notice>{authMessage(isApiError(signIn.error) ? signIn.error.code : undefined, errorMessage(signIn.error))}</Notice>}
          <button type="submit" className="cta lime" disabled={!email || !password || signIn.isPending}>
            {signIn.isPending ? 'Logging in…' : 'Log in'}
          </button>
          <p className="muted small center">
            New here? <Link to="/signup">Sign up and get free sedis</Link>
          </p>
        </form>
      )}
      {step.name === 'forgot' && (
        <form
          className="auth-form"
          onSubmit={(e) => {
            e.preventDefault()
            forgot.mutate()
          }}
        >
          <div className="auth-intro">
            <h1>Reset your password.</h1>
            <p>We’ll email you a code.</p>
          </div>
          <div className="field">
            <label htmlFor="f-email">Email</label>
            <div className="field-box">
              <input id="f-email" type="email" autoComplete="email" value={email} onChange={(e) => setEmail(e.target.value.trim())} required />
            </div>
          </div>
          <Notice error={forgot.error} />
          <button type="submit" className="cta lime" disabled={!email || forgot.isPending}>
            {forgot.isPending ? 'Sending…' : 'Send code'}
          </button>
          <button type="button" className="cta ghost" onClick={() => setStep({ name: 'login' })}>
            Back to log in
          </button>
        </form>
      )}
      {step.name === 'reset' && (
        <ResetForm
          email={step.email}
          onDone={() => {
            setResetDone(true)
            setStep({ name: 'login' })
          }}
        />
      )}
      {step.name === 'verify' && <VerifyStep token={step.token} masked={step.masked} resendAt={null} onVerified={verified} />}
      {step.name === 'done' && <Welcome username={step.username} grant={step.grant} />}
    </AuthLayout>
  )
}

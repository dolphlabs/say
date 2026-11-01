import { useEffect, useRef, useState, type ReactNode } from 'react'
import { Link } from '@tanstack/react-router'
import { Logo } from '../../ui/kit'

export function AuthLayout({ children, aside }: { children: ReactNode; aside: { to: '/login' | '/signup'; label: string } }) {
  return (
    <div className="auth-page">
      <header className="auth-header">
        <Logo compact />
        <Link to={aside.to} className="auth-switch">
          {aside.label}
        </Link>
      </header>
      <main className="auth-main">{children}</main>
    </div>
  )
}

export function GoogleButton({ intent }: { intent: 'signup' | 'login' }) {
  return (
    <a href={`/v1/auth/google/start?intent=${intent}`} className="google-button">
      <span aria-hidden="true" className="g-mark">
        G
      </span>
      Continue with Google
    </a>
  )
}

export const Divider = ({ children }: { children: ReactNode }) => (
  <div className="divider" aria-hidden="true">
    <span />
    {children}
    <span />
  </div>
)

export function PasswordInput({ id, value, onChange, autoComplete, placeholder }: { id: string; value: string; onChange: (v: string) => void; autoComplete: string; placeholder?: string }) {
  const [shown, setShown] = useState(false)
  return (
    <div className="field-box with-action">
      <input id={id} type={shown ? 'text' : 'password'} value={value} onChange={(e) => onChange(e.target.value)} autoComplete={autoComplete} placeholder={placeholder} maxLength={128} required />
      <button type="button" aria-label={shown ? 'Hide password' : 'Show password'} aria-pressed={shown} onClick={() => setShown(!shown)}>
        {shown ? 'Hide' : 'Show'}
      </button>
    </div>
  )
}

export function strength(password: string) {
  const len = password.length
  if (len === 0) return { score: 0, text: 'At least 8 characters.' }
  if (len < 8) return { score: 1, text: `${8 - len} more to go.` }
  if (len < 12 && !/[^a-zA-Z]/.test(password)) return { score: 2, text: 'Good. A number or symbol makes it stronger.' }
  return { score: 3, text: 'Strong.' }
}

export function StrengthMeter({ password }: { password: string }) {
  const { score, text } = strength(password)
  return (
    <>
      <div className={`meter s${score}`} aria-hidden="true">
        <span />
        <span />
        <span />
      </div>
      <p className={`field-note s${score}`} role="status">
        {text}
      </p>
    </>
  )
}

export function CodeInput({ value, onChange, invalid }: { value: string; onChange: (v: string) => void; invalid: boolean }) {
  const input = useRef<HTMLInputElement>(null)
  useEffect(() => input.current?.focus(), [])
  return (
    <div className="code-input" onClick={() => input.current?.focus()}>
      <div className="code-boxes" aria-hidden="true">
        {Array.from({ length: 6 }, (_, i) => (
          <span key={i} className={invalid ? 'bad' : i === value.length ? 'active' : value[i] ? 'filled' : ''}>
            {value[i] ?? ''}
          </span>
        ))}
      </div>
      <input
        ref={input}
        id="code"
        value={value}
        onChange={(e) => onChange(e.target.value.replace(/\D/g, '').slice(0, 6))}
        inputMode="numeric"
        autoComplete="one-time-code"
        maxLength={6}
        aria-invalid={invalid}
      />
    </div>
  )
}

export function useResendTimer(availableAt: string | null) {
  const [now, setNow] = useState(() => Date.now())
  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), 1000)
    return () => clearInterval(id)
  }, [])
  const at = availableAt ? new Date(availableAt).getTime() : 0
  const wait = Math.max(0, Math.ceil((at - now) / 1000))
  return { wait, label: `${Math.floor(wait / 60)}:${String(wait % 60).padStart(2, '0')}` }
}

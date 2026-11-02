import { useEffect, useState, type ReactNode } from 'react'
import { Link } from '@tanstack/react-router'
import { errorMessage } from '../api'
import { remaining } from '../format'

export function Logo({ compact = false, to = '/' }: { compact?: boolean; to?: string }) {
  return (
    <Link to={to} className={compact ? 'logo compact' : 'logo'} aria-label="say home">
      <img className="logo-mark" src="/brand/svg/mark.svg" alt="" />
      <img className="logo-word" src="/brand/svg/wordmark-white.svg" alt="say" />
    </Link>
  )
}

export function Notice({ error, children }: { error?: unknown; children?: ReactNode }) {
  if (!error && !children) return null
  return (
    <p className="notice" role="alert">
      {children ?? errorMessage(error)}
    </p>
  )
}

export function Empty({ title, children, action }: { title?: string; children?: ReactNode; action?: ReactNode }) {
  return (
    <div className="empty">
      {title && <strong>{title}</strong>}
      {children && <span>{children}</span>}
      {action}
    </div>
  )
}

export const Loading = ({ label = 'Loading…' }: { label?: string }) => (
  <p className="loading" role="status">
    {label}
  </p>
)

export function SidePill({ outcome }: { outcome: string }) {
  const yes = outcome.toUpperCase() === 'YES'
  return <span className={`side-pill ${yes ? 'yes' : 'no'}`}>{yes ? 'Yes' : 'No'}</span>
}

export type Tone = 'green' | 'red' | 'orange' | 'blue' | 'purple' | 'pink' | 'cyan' | 'lime' | 'grey' | 'white'

export const Chip = ({ tone, children }: { tone: Tone; children: ReactNode }) => <span className={`chip tone-${tone}`}>{children}</span>

export function Avatar({ name, color, size = 'md' }: { name: string; color?: string; size?: 'sm' | 'md' | 'lg' | 'xl' }) {
  return (
    <span className={`avatar ${size}`} style={color ? { background: color } : undefined} aria-hidden="true">
      {name.charAt(0).toUpperCase()}
    </span>
  )
}

export function Gauge({ pct, muted }: { pct: number | null; muted?: boolean }) {
  const value = pct == null ? 0 : Math.max(0, Math.min(100, Math.round(pct)))
  const color = muted || pct == null ? 'var(--grey-strong)' : value >= 50 ? 'var(--green)' : 'var(--red)'
  return (
    <div className="gauge">
      <svg width="56" height="32" viewBox="0 0 56 32" aria-hidden="true">
        <path d="M6 29 A22 22 0 0 1 50 29" fill="none" stroke="var(--line-strong)" strokeWidth="5" strokeLinecap="round" pathLength={100} />
        {pct != null && (
          <path d="M6 29 A22 22 0 0 1 50 29" fill="none" stroke={color} strokeWidth="5" strokeLinecap="round" pathLength={100} strokeDasharray={`${value} 100`} />
        )}
      </svg>
      <strong>{pct == null ? '—' : `${value}%`}</strong>
      <small>chance</small>
    </div>
  )
}

export function useNow(intervalMs = 1000) {
  const [now, setNow] = useState(() => Date.now())
  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), intervalMs)
    return () => clearInterval(id)
  }, [intervalMs])
  return now
}

export function Countdown({ until, seconds = true, className = '' }: { until: string | number | null | undefined; seconds?: boolean; className?: string }) {
  const now = useNow(seconds ? 1000 : 30_000)
  const left = remaining(until, now)
  if (!left) return null
  const parts: [number, string][] = [
    [left.days, 'days'],
    [left.hours, 'hrs'],
    [left.minutes, 'min'],
  ]
  if (seconds) parts.push([left.seconds, 'sec'])
  return (
    <div className={`countdown ${className}`} role="timer" aria-label={`${left.days} days ${left.hours} hours ${left.minutes} minutes left`}>
      {parts.map(([value, unit]) => (
        <div key={unit}>
          <strong>{String(value).padStart(2, '0')}</strong>
          <small>{unit}</small>
        </div>
      ))}
    </div>
  )
}

export function Segmented<T extends string>({
  label,
  value,
  options,
  onChange,
  className = '',
}: {
  label: string
  value: T
  options: readonly (readonly [T, string])[]
  onChange: (value: T) => void
  className?: string
}) {
  return (
    <div role="group" aria-label={label} className={`segmented ${className}`}>
      {options.map(([key, text]) => (
        <button type="button" key={key} aria-pressed={value === key} onClick={() => onChange(key)}>
          {text}
        </button>
      ))}
    </div>
  )
}

export function Tabs<T extends string>({
  label,
  value,
  tabs,
  onChange,
}: {
  label: string
  value: T
  tabs: readonly { key: T; label: string; count?: number | null }[]
  onChange: (value: T) => void
}) {
  return (
    <div role="tablist" aria-label={label} className="tabs">
      {tabs.map((tab) => (
        <button type="button" role="tab" key={tab.key} aria-selected={value === tab.key} onClick={() => onChange(tab.key)}>
          {tab.label}
          {tab.count != null && <span className="count">{tab.count}</span>}
        </button>
      ))}
    </div>
  )
}

export function Pager({ cursor, next, onFirst, onNext }: { cursor: string; next: string | null | undefined; onFirst: () => void; onNext: (cursor: string) => void }) {
  if (!cursor && !next) return null
  return (
    <div className="pager">
      {cursor && (
        <button type="button" className="button ghost small" onClick={onFirst}>
          First page
        </button>
      )}
      {next && (
        <button type="button" className="button ghost small" onClick={() => onNext(next)}>
          Next page
        </button>
      )}
    </div>
  )
}

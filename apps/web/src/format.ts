const TIME_ZONE = 'Africa/Lagos'

const whole = new Intl.NumberFormat('en-US', { maximumFractionDigits: 0 })
const oneDecimal = new Intl.NumberFormat('en-US', { maximumFractionDigits: 1 })

type Amount = number | null | undefined

export const number = (value: Amount) => (value == null ? '—' : whole.format(value))

export const sedi = (value: Amount) => (value == null ? '—' : `S ${whole.format(value)}`)

export function signedSedi(value: Amount) {
  if (value == null) return '—'
  if (value === 0) return 'S 0'
  return `${value > 0 ? '+' : '−'}S ${whole.format(Math.abs(value))}`
}

export function compactSedi(value: Amount) {
  if (value == null) return '—'
  const abs = Math.abs(value)
  if (abs >= 1_000_000) return `S ${oneDecimal.format(value / 1_000_000)}M`
  if (abs >= 10_000) return `S ${whole.format(value / 1000)}k`
  return sedi(value)
}

export const percent = (value: Amount) => (value == null ? '—' : `${Math.round(value)}%`)

export const tone = (value: Amount) => (value == null || value === 0 ? 'neutral' : value > 0 ? 'up' : 'down')

export const ordinal = (value: number | null | undefined) => (value == null ? '—' : String(value).padStart(2, '0'))

function toDate(value: string | number | null | undefined) {
  if (value == null || value === '') return null
  const parsed = new Date(value)
  return Number.isNaN(parsed.getTime()) ? null : parsed
}

const formatter = (options: Intl.DateTimeFormatOptions) => new Intl.DateTimeFormat('en-GB', { timeZone: TIME_ZONE, ...options })

const longFormat = formatter({ weekday: 'short', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit', hour12: false })
const dayFormat = formatter({ weekday: 'short', day: 'numeric', month: 'short' })
const timeFormat = formatter({ hour: '2-digit', minute: '2-digit', hour12: false })
const monthFormat = formatter({ month: 'short', year: 'numeric' })
const weekdayTimeFormat = formatter({ weekday: 'short', hour: '2-digit', minute: '2-digit', hour12: false })

export function weekdayTime(value: string | number | null | undefined) {
  const parsed = toDate(value)
  return parsed ? weekdayTimeFormat.format(parsed).replace(',', '') : '—'
}

export function dateTime(value: string | number | null | undefined) {
  const parsed = toDate(value)
  return parsed ? `${longFormat.format(parsed).replace(',', '')} WAT` : '—'
}

export function day(value: string | number | null | undefined) {
  const parsed = toDate(value)
  return parsed ? dayFormat.format(parsed).replace(',', '') : '—'
}

export function clock(value: string | number | null | undefined) {
  const parsed = toDate(value)
  return parsed ? timeFormat.format(parsed) : '—'
}

export function month(value: string | number | null | undefined) {
  const parsed = toDate(value)
  return parsed ? monthFormat.format(parsed) : '—'
}

export type Remaining = { days: number; hours: number; minutes: number; seconds: number; done: boolean }

export function remaining(until: string | number | null | undefined, now = Date.now()): Remaining | null {
  const parsed = toDate(until)
  if (!parsed) return null
  const left = Math.max(0, parsed.getTime() - now)
  const seconds = Math.floor(left / 1000)
  return {
    days: Math.floor(seconds / 86400),
    hours: Math.floor((seconds % 86400) / 3600),
    minutes: Math.floor((seconds % 3600) / 60),
    seconds: seconds % 60,
    done: left === 0,
  }
}

export function timeLeft(until: string | number | null | undefined, now = Date.now()) {
  const left = remaining(until, now)
  if (!left) return ''
  if (left.done) return 'ended'
  if (left.days > 0) return `${left.days}d ${left.hours}h left`
  if (left.hours > 0) return `${left.hours}h ${left.minutes}m left`
  return `${left.minutes}m ${String(left.seconds).padStart(2, '0')}s left`
}

export function ago(value: string | number | null | undefined, now = Date.now()) {
  const parsed = toDate(value)
  if (!parsed) return ''
  const minutes = Math.round((now - parsed.getTime()) / 60000)
  if (minutes < 1) return 'now'
  if (minutes < 60) return `${minutes}m`
  if (minutes < 24 * 60) return `${Math.round(minutes / 60)}h`
  return day(parsed.getTime())
}

export const titleCase = (value: string) => value.toLowerCase().replace(/(^|[_\s-])(\w)/g, (_, gap: string, letter: string) => (gap ? ' ' : '') + letter.toUpperCase())

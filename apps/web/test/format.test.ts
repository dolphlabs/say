import { describe, expect, it } from 'vitest'
import { compactSedi, dateTime, remaining, sedi, signedSedi, timeLeft } from '../src/format'

describe('formatting', () => {
  it('should keep missing values distinct from zero', () => {
    expect(sedi(null)).toBe('—')
    expect(sedi(undefined)).toBe('—')
    expect(sedi(0)).toBe('S 0')
    expect(signedSedi(null)).toBe('—')
    expect(compactSedi(null)).toBe('—')
  })

  it('should sign gains and losses', () => {
    expect(signedSedi(514)).toBe('+S 514')
    expect(signedSedi(-151)).toBe('−S 151')
    expect(signedSedi(0)).toBe('S 0')
  })

  it('should compact large volumes', () => {
    expect(compactSedi(724_000)).toBe('S 724k')
    expect(compactSedi(3_400_000)).toBe('S 3.4M')
    expect(compactSedi(9_999)).toBe('S 9,999')
  })

  it('should show times in West Africa Time', () => {
    expect(dateTime('2026-10-25T15:00:00Z')).toBe('Sun 25 Oct 16:00 WAT')
    expect(dateTime(null)).toBe('—')
  })

  it('should count down without going negative', () => {
    const now = Date.parse('2026-10-19T00:00:00Z')
    expect(remaining('2026-10-26T04:12:30Z', now)).toEqual({ days: 7, hours: 4, minutes: 12, seconds: 30, done: false })
    expect(remaining('2026-10-18T00:00:00Z', now)?.done).toBe(true)
    expect(timeLeft('2026-10-26T04:12:30Z', now)).toBe('7d 4h left')
  })
})

import { get, post } from '../../api'
import type { SignedIn } from '../../session'

export type UsernameCheck = { username: string; available: boolean; reason?: string; suggestions: string[] }
export type Hold = { username: string; hold_id: string; expires_at: string }
export type Signup = { signup_token: string; email_masked: string; resend_available_at: string }

export const USERNAME_PATTERN = /^[a-z0-9][a-z0-9._]{1,18}[a-z0-9_]$/

export const normalizeUsername = (raw: string) =>
  raw
    .toLowerCase()
    .replace(/[^a-z0-9._]/g, '')
    .slice(0, 20)

export const checkUsername = (name: string) => get<UsernameCheck>(`/v1/auth/username/${encodeURIComponent(name)}`)
export const holdUsername = (username: string) => post<Hold>('/v1/auth/username/hold', { username })
export const signup = (body: { username: string; hold_id: string; email: string; password: string }) => post<Signup>('/v1/auth/signup', body)
export const verifyCode = (signup_token: string, code: string) => post<SignedIn>('/v1/auth/otp/verify', { signup_token, code })
export const resendCode = (signup_token: string) => post<{ resend_available_at: string }>('/v1/auth/otp/resend', { signup_token, purpose: 'verify_email' })
export const completeGoogle = (body: { pending_token: string; username: string; hold_id: string }) => post<SignedIn>('/v1/auth/google/complete', body)
export const login = (email: string, password: string) => post<SignedIn>('/v1/auth/login', { email, password })
export const forgotPassword = (email: string) => post('/v1/auth/password/forgot', { email })
export const resetPassword = (email: string, code: string, new_password: string) => post('/v1/auth/password/reset', { email, code, new_password })

const AUTH_MESSAGES: Record<string, string> = {
  INVALID_CREDENTIALS: 'That email and password don’t match.',
  GOOGLE_EMAIL_IN_USE: 'That Google email already has a say account. Log in with your password, then link Google in Settings.',
  GOOGLE_LINKED_ELSEWHERE: 'That Google account belongs to another say account.',
  GOOGLE_FAILED: 'Google didn’t answer. Try again.',
  PENDING_EXPIRED: 'That took too long. Start again.',
}

export const authMessage = (code: string | undefined, fallback: string) => (code && AUTH_MESSAGES[code]) || fallback

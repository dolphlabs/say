export type FieldError = { field: string; reason?: string; message?: string }

export class ApiError extends Error {
  constructor(
    public status: number,
    public code: string,
    message: string,
    public details: Record<string, unknown> = {},
  ) {
    super(message)
  }

  get fields(): FieldError[] {
    return Array.isArray(this.details.fields) ? (this.details.fields as FieldError[]) : []
  }
}

type ErrorBody = { error?: { code?: string; message?: string; [key: string]: unknown } }

const UNREACHABLE = 'Unable to reach say. Check your connection and try again.'

export async function request<T>(path: string, init: RequestInit = {}): Promise<T> {
  const headers = new Headers(init.headers)
  if (init.body !== undefined && !headers.has('Content-Type')) headers.set('Content-Type', 'application/json')
  const response = await fetch(path, { ...init, credentials: 'same-origin', headers })
  if (!response.ok) {
    const body = (await response.json().catch(() => null)) as ErrorBody | null
    const error = body?.error ?? {}
    throw new ApiError(response.status, error.code ?? 'UNAVAILABLE', error.message ?? UNREACHABLE, error)
  }
  if (response.status === 204) return undefined as T
  const text = await response.text()
  return (text ? JSON.parse(text) : undefined) as T
}

export const get = <T>(path: string) => request<T>(path)

export const send = <T>(method: 'POST' | 'PUT' | 'PATCH' | 'DELETE', path: string, body?: unknown, headers?: HeadersInit) =>
  request<T>(path, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) })

export const post = <T>(path: string, body: unknown = {}, headers?: HeadersInit) => send<T>('POST', path, body, headers)

export function query(params: Record<string, string | number | null | undefined>): string {
  const search = new URLSearchParams()
  for (const [key, value] of Object.entries(params)) {
    if (value !== undefined && value !== null && value !== '') search.set(key, String(value))
  }
  const text = search.toString()
  return text ? `?${text}` : ''
}

export const isApiError = (error: unknown, ...codes: string[]): error is ApiError =>
  error instanceof ApiError && (codes.length === 0 || codes.includes(error.code))

export const errorMessage = (error: unknown) =>
  error instanceof Error && error.message ? error.message : 'Something went wrong. Please try again.'

export type Page<T> = { items: T[]; next_cursor: string | null }

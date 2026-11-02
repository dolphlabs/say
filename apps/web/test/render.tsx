import type { ReactNode } from 'react'
import { render } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { createMemoryHistory, createRootRoute, createRouter, RouterProvider } from '@tanstack/react-router'
import { vi } from 'vitest'
import { ToastProvider } from '../src/ui/toast'

export type Handler = (url: string, init: RequestInit | undefined) => unknown

export const json = (body: unknown, status = 200) => new Response(body === undefined ? null : JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } })

export function stubFetch(handler: Handler) {
  const fetcher = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const result = handler(String(input), init)
    if (result instanceof Error) throw result
    if (result instanceof Response) return result
    return json(result ?? {})
  })
  vi.stubGlobal('fetch', fetcher)
  return fetcher
}

export function client() {
  return new QueryClient({ defaultOptions: { queries: { retry: false, refetchInterval: false }, mutations: { retry: false } } })
}

export function renderWithApp(ui: () => ReactNode, queryClient = client()) {
  const root = createRootRoute({ component: () => <>{ui()}</> })
  const router = createRouter({ routeTree: root, history: createMemoryHistory({ initialEntries: ['/'] }) })
  const view = render(
    <QueryClientProvider client={queryClient}>
      <ToastProvider>
        <RouterProvider router={router} />
      </ToastProvider>
    </QueryClientProvider>,
  )
  return { ...view, queryClient }
}

export const user = { id: 'u-1', username: 'kemi.calls', email: 'kemi@example.test', email_verified: true, has_password: true, google_linked: false, username_changeable_at: null, roles: [] as string[] }

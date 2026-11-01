import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { MutationCache, QueryCache, QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { createRootRoute, createRoute, createRouter, lazyRouteComponent, Navigate, Outlet, RouterProvider } from '@tanstack/react-router'
import { ApiError } from './api'
import { endSession } from './session'
import { ToastProvider } from './ui/toast'
import { Empty } from './ui/kit'
import { Home } from './features/markets/Home'
import { MarketDetail } from './features/markets/MarketDetail'
import { HowItWorks } from './features/markets/HowItWorks'
import { LoginPage } from './features/auth/Login'
import { GoogleSignupPage, SignupPage } from './features/auth/Signup'
import { PortfolioPage } from './features/portfolio/Portfolio'
import { LeaderboardPage } from './features/standings/Leaderboard'
import { ProfilePage } from './features/profile/Profile'
import { PlayerLayout } from './shell'
import './style.css'

const optionalString = (value: unknown) => (typeof value === 'string' && value ? value : undefined)

function NotFound() {
  return (
    <PlayerLayout>
      <main className="container narrow">
        <Empty title="Nothing here">That page doesn’t exist.</Empty>
      </main>
    </PlayerLayout>
  )
}

const root = createRootRoute({ component: Outlet, notFoundComponent: NotFound })

const routeTree = root.addChildren([
  createRoute({ getParentRoute: () => root, path: '/', component: Home, validateSearch: (s: Record<string, unknown>) => ({ q: optionalString(s.q) }) }),
  createRoute({ getParentRoute: () => root, path: '/markets/$selector', component: MarketDetail }),
  createRoute({ getParentRoute: () => root, path: '/portfolio', component: PortfolioPage }),
  createRoute({ getParentRoute: () => root, path: '/leaderboard', component: LeaderboardPage }),
  createRoute({ getParentRoute: () => root, path: '/how-it-works', component: HowItWorks }),
  createRoute({ getParentRoute: () => root, path: '/login', component: LoginPage, validateSearch: (s: Record<string, unknown>) => ({ error: optionalString(s.error) }) }),
  createRoute({ getParentRoute: () => root, path: '/signup', component: SignupPage }),
  createRoute({
    getParentRoute: () => root,
    path: '/signup/google',
    component: GoogleSignupPage,
    validateSearch: (s: Record<string, unknown>) => ({ pending_token: optionalString(s.pending_token), email: optionalString(s.email) }),
  }),
  createRoute({ getParentRoute: () => root, path: '/settings', component: ProfilePage, validateSearch: (s: Record<string, unknown>) => ({ google: optionalString(s.google) }) }),
  createRoute({ getParentRoute: () => root, path: '/users/$username', component: ProfilePage }),
  createRoute({ getParentRoute: () => root, path: '/u/$username', component: ProfilePage }),
  createRoute({ getParentRoute: () => root, path: '/admin', component: () => <Navigate to="/admin/$section" params={{ section: 'markets' }} replace /> }),
  createRoute({ getParentRoute: () => root, path: '/admin/$section', component: lazyRouteComponent(() => import('./features/admin/AdminPage'), 'AdminPage') }),
])

const router = createRouter({ routeTree, scrollRestoration: true })

declare module '@tanstack/react-router' {
  interface Register {
    router: typeof router
  }
}

// A 401 on any private read means the session ended elsewhere (logout,
// password change, revocation): drop private data instead of showing it stale.
const onUnauthenticated = (error: unknown) => {
  if (error instanceof ApiError && error.code === 'UNAUTHENTICATED' && queryClient.getQueryData(['me'])) {
    void endSession(queryClient)
  }
}

const queryClient: QueryClient = new QueryClient({
  queryCache: new QueryCache({ onError: onUnauthenticated }),
  mutationCache: new MutationCache({ onError: onUnauthenticated }),
  defaultOptions: { queries: { retry: (count, error) => !(error instanceof ApiError && error.status < 500) && count < 2, refetchOnWindowFocus: true, staleTime: 10_000 } },
})

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <QueryClientProvider client={queryClient}>
      <ToastProvider>
        <RouterProvider router={router} />
      </ToastProvider>
    </QueryClientProvider>
  </StrictMode>,
)

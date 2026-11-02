import { useQuery } from '@tanstack/react-query'
import { get, query, type Page } from '../../api'

export type Summary = {
  season: { ordinal: number; status: string; ends_at: string }
  available: number
  held: number
  held_shares: { market_id: string; outcome: string; qty: number }[]
  positions_value: number
  total: number
  season_pnl: number | null
  starting_grant: number | null
  rank: { position: number; of: number } | null
}

export type Result = {
  market: { id: string; slug: string; question: string; category: string; status: string; closes_at: string; redemption_units: number }
  outcome: string
  qty: number
  avg_price: { numerator: number; denominator: number }
  result: string
  paid_out: number
  pnl: number
  settled_at: string
}

export type LedgerItem = {
  id: string
  at: string
  kind: string
  delta: number
  held_delta: number
  available_after: number | null
  held_after: number | null
  ref: { type: string; id: string }
  shares: { asset: string; delta: number; held_delta: number }[]
  meta: Record<string, unknown> | null
}

export type Notification = { id: string; kind: string; title: string; body: string; link: string; created_at: string; unread: boolean }

export const useSummary = (enabled: boolean) =>
  useQuery({ queryKey: ['summary'], queryFn: () => get<Summary>('/v1/me/portfolio/summary'), enabled, refetchInterval: 15_000, retry: false })

export const useResults = (enabled: boolean) => useQuery({ queryKey: ['results'], queryFn: () => get<{ items: Result[] }>('/v1/me/results'), enabled })

export const useLedger = (enabled: boolean, cursor: string) =>
  useQuery({ queryKey: ['ledger', cursor], queryFn: () => get<Page<LedgerItem>>(`/v1/me/ledger${query({ cursor })}`), enabled })

export const useNotifications = (enabled: boolean) =>
  useQuery({
    queryKey: ['notifications'],
    queryFn: () => get<Page<Notification> & { unread_count: number }>('/v1/me/notifications'),
    enabled,
    refetchInterval: 30_000,
  })

const LEDGER_LABELS: Record<string, string> = {
  SEASON_GRANT: 'Season starting balance',
  ORDER_HOLD: 'Held for an order',
  ORDER_RELEASE: 'Released from an order',
  FILL: 'Order filled',
  FEE: 'Order fee',
  MINT: 'Shares issued',
  MERGE: 'Shares merged',
  PAYOUT: 'Payout',
  VOID_REFUND: 'Refund · market voided',
  FEE_REFUND: 'Fee refunded',
  ADJUSTMENT: 'Adjustment',
}

export const ledgerLabel = (item: LedgerItem) => {
  const label = typeof item.meta?.label === 'string' ? item.meta.label : null
  return label ?? LEDGER_LABELS[item.kind] ?? item.kind.replaceAll('_', ' ').toLowerCase()
}

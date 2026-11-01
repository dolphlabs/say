import { useQuery } from '@tanstack/react-query'
import { ApiError, get, query, type Page } from '../../api'

export type Category = { id: string; name: string; icon: string; open_count: number }

export type MarketCard = {
  id: string
  slug: string
  question: string
  category: { id: string; name?: string; icon?: string }
  status: string
  status_note: string
  closes_at: string | null
  closing_soon: boolean
  redemption_units: number
  last_price: number | null
  chance_pct: number | null
  yes_ask: number | null
  no_ask: number | null
  volume_units: number | null
  change_24h: number | null
}

export type Market = MarketCard & {
  rules: { yes_if: string; no_if: string; edge_cases: string }
  resolve_by: string | null
  price_band: { min: number; max: number; tick: number }
  max_order_qty: number
  fee_units: number
  resolution_source?: { name: string; url: string }
  season?: { ordinal: number; ends_at: string | null }
}

export type Season = { id: string; ordinal: number; status: string; starts_at: string; ends_at: string; day: number; days_total: number }

export type Level = { yes_price: number; qty: number }

export type Book = { market_id: string; last_price: number | null; bids: Level[]; asks: Level[]; health: string; mode: string }

export type Trade = { execution_seq: number; fill_index: number; mode: string; qty: number; yes_price: number; created_at: string }

export type Candle = { bucket_at: string; open: number; high: number; low: number; close: number; volume: number }

export type Period = '1H' | '6H' | '1D' | '1W' | 'ALL'

export type StandingRow = { rank: number; account_id: string; username: string; avatar_color: string; calls: number; win_rate: string; profit: number }

export type PublicResolution = {
  state: string
  proposed_outcome: string
  dispute_until: string
  evidence: { source: string; finding: string; verdict: string; retrieved_at: string; snapshot_url: string; sha256: string }[]
  final?: { outcome: string; reason: string; decided_at: string }
}

export type Filter = 'trending' | 'ending_soon' | 'new'

export const TRADABLE = new Set(['OPEN'])

export const isTradable = (m: Pick<MarketCard, 'status'>) => TRADABLE.has(m.status)

const orNull = async <T>(load: () => Promise<T>): Promise<T | null> => {
  try {
    return await load()
  } catch (error) {
    if (error instanceof ApiError && error.status === 404) return null
    throw error
  }
}

export const useCategories = () => useQuery({ queryKey: ['categories'], queryFn: () => get<Category[]>('/v1/categories'), staleTime: 300_000 })

export const useSeason = () =>
  useQuery({ queryKey: ['season'], queryFn: () => orNull(() => get<Season>('/v1/seasons/current')), staleTime: 60_000 })

export const useFeatured = () => useQuery({ queryKey: ['featured'], queryFn: () => orNull(() => get<MarketCard>('/v1/markets/featured')) })

export const useLeaderStrip = () =>
  useQuery({ queryKey: ['leaderboard', 'strip'], queryFn: () => get<{ items: StandingRow[] }>('/v1/leaderboard/strip'), staleTime: 60_000 })

export const marketsPath = (filter: Filter, category: string, cursor: string) => `/v1/markets${query({ filter, category, cursor })}`

export const searchPath = (term: string) => `/v1/markets/search${query({ q: term })}`

export const useMarket = (selector: string) =>
  useQuery({ queryKey: ['market', selector], queryFn: () => get<Market>(`/v1/markets/${encodeURIComponent(selector)}`) })

export const useBook = (id: string | undefined) =>
  useQuery({ queryKey: ['book', id], queryFn: () => get<Book>(`/v1/markets/${id}/book`), enabled: !!id, refetchInterval: 10_000, retry: false })

export const useTrades = (id: string | undefined) =>
  useQuery({ queryKey: ['trades', id], queryFn: () => get<Page<Trade>>(`/v1/markets/${id}/trades?limit=12`), enabled: !!id, refetchInterval: 15_000 })

export const useHistory = (id: string | undefined, period: Period) =>
  useQuery({ queryKey: ['history', id, period], queryFn: () => get<{ items: Candle[] }>(`/v1/markets/${id}/history?period=${period}`), enabled: !!id, refetchInterval: 30_000 })

export const usePublicResolution = (id: string | undefined, enabled: boolean) =>
  useQuery({
    queryKey: ['resolution', id],
    queryFn: () => orNull(() => get<PublicResolution>(`/v1/markets/${id}/resolution`)),
    enabled: !!id && enabled,
    retry: false,
  })

export function tradeSide(trade: Trade, redemption: number) {
  if (trade.mode === 'TRANSFER_NO') return { outcome: 'NO', price: redemption - trade.yes_price }
  return { outcome: 'YES', price: trade.yes_price }
}

export function noPrice(yesPrice: number | null | undefined, redemption: number) {
  return yesPrice == null ? null : redemption - yesPrice
}

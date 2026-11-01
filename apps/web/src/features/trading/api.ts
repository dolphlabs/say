import { useQuery } from '@tanstack/react-query'
import { get, query, type Page } from '../../api'

export type Outcome = 'YES' | 'NO'
export type Side = 'BUY' | 'SELL'
export type OrderType = 'market' | 'limit'
export type Tif = 'GTC' | 'IOC'

export type OrderIntent =
  | { type: 'market'; outcome: Outcome; side: 'BUY'; spend: number }
  | { type: 'market'; outcome: Outcome; side: 'SELL'; qty: number }
  | { type: 'limit'; outcome: Outcome; side: Side; price: number; qty: number; tif: Tif }

export type Order = {
  id: string
  order_id: string
  market_id: string
  status: string
  status_label: string
  outcome: Outcome
  side: Side
  price: number
  qty: number
  remaining: number
  filled_qty: number
  principal: number
  fee_charged: number
  avg_price: number | null
  held: { sedi: number; shares: number }
  placed_at: string
  cancellable: boolean
  command_id?: string
}

export type Pending = { order_id: string; command_id: string; status: 'ADMITTED' | 'CANCEL_PENDING' | string; existing: boolean }

export type Admission = Order | Pending

export const isCommitted = (a: Admission): a is Order => 'status_label' in a

export const OPEN_STATUSES = new Set(['ADMITTED', 'OPEN', 'PARTIAL'])

export type Position = {
  market: { id: string; slug: string; question: string; category: string; status: string; closes_at: string; redemption_units: number }
  outcome: Outcome
  qty: number
  qty_free: number
  qty_in_orders: number
  avg_price: { numerator: number; denominator: number }
  mark: { numerator: number; denominator: number }
  mark_source: string
  value: number
  unrealized_pnl: number
  pnl_pct: number | null
  proposed_outcome?: string
}

export const ratio = (r: { numerator: number; denominator: number }) => (r.denominator ? r.numerator / r.denominator : null)

export const useOpenOrders = (enabled: boolean, marketId = '', cursor = '') =>
  useQuery({
    queryKey: ['orders', marketId, cursor],
    queryFn: () => get<Page<Order>>(`/v1/me/orders${query({ status: 'open', market_id: marketId, cursor })}`),
    enabled,
    refetchInterval: 10_000,
  })

export const usePositions = (enabled: boolean) =>
  useQuery({ queryKey: ['positions'], queryFn: () => get<{ items: Position[] }>('/v1/me/positions'), enabled, refetchInterval: 15_000 })

export function orderTitle(o: Pick<Order, 'side' | 'qty' | 'price'>) {
  return `${o.side === 'BUY' ? 'Buy' : 'Sell'} ${o.qty} @ S ${o.price}`
}

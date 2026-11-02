import { useCallback, useEffect, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { ApiError, get, post } from '../../api'
import { isCommitted, type Admission, type Order, type OrderIntent } from './api'

type Stored = { body: string; key: string }

const storageKey = (userId: string, marketId: string) => `say:order-intent:${userId}:${marketId}`

function readStored(key: string): Stored | null {
  try {
    const raw = sessionStorage.getItem(key)
    if (!raw) return null
    const parsed = JSON.parse(raw) as Stored
    return typeof parsed.body === 'string' && typeof parsed.key === 'string' ? parsed : null
  } catch {
    return null
  }
}

function writeStored(key: string, value: Stored | null) {
  try {
    if (value) sessionStorage.setItem(key, JSON.stringify(value))
    else sessionStorage.removeItem(key)
  } catch {
    return
  }
}

export class UnresolvedIntentError extends Error {
  constructor() {
    super('Your previous order may already have been accepted. Retry it with the same details, or check your open orders before placing a different one.')
  }
}

// A 4xx is the server's definite answer for that intent; anything else
// (network failure, 5xx) leaves it unknown, so the key must be reused.
const isDefinite = (error: unknown) => error instanceof ApiError && error.status < 500

export function useOrderSubmission(marketId: string, userId: string | undefined, onSettled: (order: Order) => void) {
  const client = useQueryClient()
  const key = userId ? storageKey(userId, marketId) : ''
  const [unresolved, setUnresolved] = useState<OrderIntent | null>(null)
  const [trackedId, setTrackedId] = useState<string | null>(null)

  useEffect(() => {
    const stored = key ? readStored(key) : null
    setUnresolved(stored ? (JSON.parse(stored.body) as OrderIntent) : null)
  }, [key])

  const refreshPrivate = useCallback(() => {
    for (const k of ['summary', 'positions', 'orders', 'ledger']) void client.invalidateQueries({ queryKey: [k] })
  }, [client])

  const mutation = useMutation({
    mutationFn: async (intent: OrderIntent) => {
      if (!key) throw new Error('Log in to place an order.')
      const body = JSON.stringify(intent)
      let stored = readStored(key)
      if (stored && stored.body !== body) throw new UnresolvedIntentError()
      if (!stored) {
        stored = { body, key: crypto.randomUUID() }
        writeStored(key, stored)
      }
      return post<Admission>(`/v1/markets/${marketId}/orders`, intent, { 'Idempotency-Key': stored.key })
    },
    onSuccess: (admission) => {
      writeStored(key, null)
      setUnresolved(null)
      refreshPrivate()
      if (isCommitted(admission)) {
        client.setQueryData(['order', admission.order_id], admission)
        onSettled(admission)
      } else {
        setTrackedId(admission.order_id)
      }
    },
    onError: (error, intent) => {
      if (error instanceof UnresolvedIntentError) return
      if (isDefinite(error)) {
        writeStored(key, null)
        setUnresolved(null)
      } else {
        setUnresolved(intent)
      }
    },
  })

  const tracked = useQuery({
    queryKey: ['order', trackedId],
    queryFn: () => get<Order>(`/v1/orders/${trackedId}`),
    enabled: !!trackedId,
    refetchInterval: (q) => (q.state.data && q.state.data.status !== 'ADMITTED' ? false : 1500),
  })

  useEffect(() => {
    if (tracked.data && tracked.data.status !== 'ADMITTED') {
      setTrackedId(null)
      refreshPrivate()
      onSettled(tracked.data)
    }
  }, [tracked.data, refreshPrivate, onSettled])

  const discard = useCallback(() => {
    writeStored(key, null)
    setUnresolved(null)
    mutation.reset()
  }, [key, mutation])

  return {
    submit: mutation.mutate,
    submitting: mutation.isPending,
    error: mutation.error,
    unresolved,
    discard,
    awaiting: !!trackedId,
    trackError: tracked.error,
  }
}

export function describeOrder(order: Order) {
  const side = order.outcome === 'YES' ? 'Yes' : 'No'
  if (order.status === 'FILLED') {
    return order.side === 'BUY'
      ? { title: `Bought ${order.filled_qty} ${side}`, body: `Avg S ${order.avg_price?.toFixed(1) ?? order.price} · fee S ${order.fee_charged}` }
      : { title: `Sold ${order.filled_qty} ${side}`, body: `S ${order.principal - order.fee_charged} added to your balance` }
  }
  if (order.status === 'PARTIAL') return { title: `${order.filled_qty} of ${order.qty} filled`, body: 'The rest waits on the book · you can cancel any time' }
  if (order.status === 'OPEN') return { title: 'Order placed', body: 'Waiting on the book · you can cancel any time' }
  return { title: order.filled_qty > 0 ? `${order.filled_qty} of ${order.qty} filled` : 'Order not filled', body: order.status_label }
}

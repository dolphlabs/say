import { Link } from '@tanstack/react-router'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { request } from '../../api'
import { number, sedi, signedSedi, tone } from '../../format'
import { Notice, SidePill } from '../../ui/kit'
import { orderTitle, ratio, useOpenOrders, type Admission, type Position } from './api'

export function useCancelOrder() {
  const client = useQueryClient()
  return useMutation({
    mutationFn: (id: string) => request<Admission>(`/v1/orders/${id}`, { method: 'DELETE' }),
    onSuccess: () => {
      for (const key of ['orders', 'summary', 'positions']) void client.invalidateQueries({ queryKey: [key] })
    },
  })
}

export function cancelStatus(result: Admission | undefined) {
  if (!result) return ''
  return result.status === 'CANCEL_PENDING' ? 'Cancelling · the held amount comes back once it’s done.' : 'Cancelled · the held amount is back in your balance.'
}

export function YourPosition({ marketId, positions }: { marketId: string; positions: Position[] }) {
  const mine = positions.filter((p) => p.market.id === marketId)
  return (
    <section className="panel side-list" aria-labelledby="pos-h">
      <div className="panel-head">
        <h2 id="pos-h">Your position</h2>
        <Link to="/portfolio" className="muted-link">
          Portfolio
        </Link>
      </div>
      {mine.length ? (
        mine.map((p) => {
          const avg = ratio(p.avg_price)
          return (
            <div className="side-row" key={p.outcome}>
              <SidePill outcome={p.outcome} />
              <span className="grow">
                {number(p.qty)} shares{avg != null && ` · avg S ${avg.toFixed(avg % 1 ? 1 : 0)}`}
                {p.qty_in_orders > 0 && <small className="muted block">{p.qty_in_orders} in a sell order</small>}
              </span>
              <div className="right">
                <strong>{sedi(p.value)}</strong>
                <small className={tone(p.unrealized_pnl)}>
                  {signedSedi(p.unrealized_pnl)}
                  {p.pnl_pct != null && ` (${p.pnl_pct > 0 ? '+' : ''}${p.pnl_pct}%)`}
                </small>
              </div>
            </div>
          )
        })
      ) : (
        <p className="muted">No shares in this market yet.</p>
      )}
    </section>
  )
}

export function MarketOrders({ marketId }: { marketId: string }) {
  const orders = useOpenOrders(true, marketId)
  const cancel = useCancelOrder()
  const items = orders.data?.items ?? []
  return (
    <section className="panel side-list" aria-labelledby="oo-h">
      <h2 id="oo-h">Open orders</h2>
      {orders.error ? (
        <Notice error={orders.error} />
      ) : items.length ? (
        items.map((o) => (
          <div className="side-row" key={o.id}>
            <SidePill outcome={o.outcome} />
            <div className="grow">
              <strong>{orderTitle(o)}</strong>
              <small className={o.status === 'ADMITTED' ? 'warn' : 'muted'}>
                {o.filled_qty > 0 ? `${o.filled_qty} of ${o.qty} filled · ` : ''}
                {o.status_label}
              </small>
            </div>
            {o.cancellable && (
              <button type="button" className="button ghost small" disabled={cancel.isPending && cancel.variables === o.id} onClick={() => cancel.mutate(o.id)}>
                Cancel
              </button>
            )}
          </div>
        ))
      ) : (
        <p className="muted">{orders.isLoading ? 'Loading…' : 'No open orders here.'}</p>
      )}
      <Notice error={cancel.error} />
      {cancel.data && (
        <p className="muted" role="status">
          {cancelStatus(cancel.data)}
        </p>
      )}
    </section>
  )
}

import { useState } from 'react'
import { clock, day, sedi } from '../../format'
import { AreaChart } from '../../ui/chart'
import { Notice, Segmented } from '../../ui/kit'
import { useHistory, type Market, type Period } from './api'

const PERIODS = [
  ['1H', '1H'],
  ['6H', '6H'],
  ['1D', '1D'],
  ['1W', '1W'],
  ['ALL', 'All'],
] as const

const PAD = 4

export function PriceChart({ market }: { market: Market }) {
  const [period, setPeriod] = useState<Period>('1W')
  const history = useHistory(market.id, period)
  const V = market.redemption_units
  const pct = (price: number) => Math.round((price / V) * 100)
  const values = (history.data?.items ?? []).map((c) => pct(c.close))
  const first = values[0]
  const last = values[values.length - 1]
  const diff = values.length > 1 ? last - first : null
  const lo = values.length ? Math.max(0, Math.min(...values) - PAD) : 0
  const hi = values.length ? Math.min(100, Math.max(...values) + PAD) : 100
  const items = history.data?.items ?? []
  const label = (iso: string) => (period === '1H' || period === '6H' || period === '1D' ? clock(iso) : day(iso))
  const chance = market.chance_pct

  return (
    <section className="panel chart-panel" aria-label="Chance over time">
      <div className="chart-head">
        <div>
          <div className="big-chance">
            <strong className={chance != null && chance < 50 ? 'down' : 'up'}>{chance == null ? '—' : `${Math.round(chance)}%`}</strong>
            {diff != null && (
              <span className={diff >= 0 ? 'up' : 'down'}>
                {diff >= 0 ? '▲' : '▼'} {Math.abs(diff)} · {period}
              </span>
            )}
          </div>
          <small className="muted">{market.last_price == null ? 'No trades yet' : `chance Yes · last trade ${sedi(market.last_price)}`}</small>
        </div>
        <Segmented label="Time range" value={period} options={PERIODS} onChange={setPeriod} className="small" />
      </div>
      {history.error ? (
        <Notice error={history.error} />
      ) : values.length > 1 ? (
        <>
          <div className="chart-frame">
            <AreaChart values={values} min={lo} max={hi} guides={[0.2, 0.5, 0.8]} label={`Chance of Yes over ${period}, from ${first}% to ${last}%`} />
            <div className="y-axis" aria-hidden="true">
              <span>{Math.round(lo + (hi - lo) * 0.8)}%</span>
              <span>{Math.round((lo + hi) / 2)}%</span>
              <span>{Math.round(lo + (hi - lo) * 0.2)}%</span>
            </div>
          </div>
          <div className="x-axis" aria-hidden="true">
            <span>{label(items[0].bucket_at)}</span>
            <span>{label(items[Math.floor(items.length / 2)].bucket_at)}</span>
            <span>Now</span>
          </div>
        </>
      ) : (
        <p className="muted chart-empty">{history.isLoading ? 'Loading price history…' : 'Not enough trades in this range for a chart yet.'}</p>
      )}
    </section>
  )
}

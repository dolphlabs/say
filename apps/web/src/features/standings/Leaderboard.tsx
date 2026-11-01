import { useState } from 'react'
import { Link } from '@tanstack/react-router'
import { useQuery } from '@tanstack/react-query'
import { get, query } from '../../api'
import { dateTime, day, number, ordinal, sedi, signedSedi, tone } from '../../format'
import { useMe } from '../../session'
import { PlayerLayout } from '../../shell'
import { Avatar, Countdown, Empty, Loading, Notice, Pager, Segmented } from '../../ui/kit'
import type { StandingRow } from '../markets/api'

type Sort = 'profit' | 'win_rate' | 'calls'

type Board = {
  season: { ordinal: number; status: string; starts_at: number; ends_at: number; players: number; provisional: boolean; provisional_reason?: string }
  podium: StandingRow[]
  items: StandingRow[]
  next_cursor: string
  me?: { rank: number; of: number; profit: number; percentile_label: string; row: StandingRow; to_top20: number | null }
}

const SORTS = [
  ['profit', 'Profit'],
  ['win_rate', 'Win rate'],
  ['calls', 'Most calls'],
] as const

const PODIUM = ['lime', 'white', 'blue']

function metric(row: StandingRow, sort: Sort) {
  if (sort === 'win_rate') return { main: row.win_rate ? `${row.win_rate} right` : 'Too few calls', sub: `${signedSedi(row.profit)} profit` }
  if (sort === 'calls') return { main: `${number(row.calls)} calls`, sub: `${signedSedi(row.profit)} profit` }
  return { main: signedSedi(row.profit), sub: `${number(row.calls)} calls${row.win_rate ? ` · ${row.win_rate} right` : ''}` }
}

function Row({ row, me }: { row: StandingRow; me?: boolean }) {
  return (
    <tr className={me ? 'me' : ''}>
      <td className="muted strong">{row.rank}</td>
      <td>
        <Link to="/users/$username" params={{ username: row.username }} className="player">
          <Avatar name={row.username} color={row.avatar_color} size="sm" />
          <span>@{row.username}</span>
          {me && <span className="you">You</span>}
        </Link>
      </td>
      <td className="num">{number(row.calls)}</td>
      <td className="num">{row.win_rate || '—'}</td>
      <td className={`num strong ${tone(row.profit)}`}>{signedSedi(row.profit)}</td>
    </tr>
  )
}

export function LeaderboardPage() {
  const { user } = useMe()
  const [sort, setSort] = useState<Sort>('profit')
  const [cursor, setCursor] = useState('')
  const board = useQuery({ queryKey: ['leaderboard', sort, cursor, user?.id ?? ''], queryFn: () => get<Board>(`/v1/leaderboard${query({ sort, cursor })}`) })
  const data = board.data
  const season = data?.season
  const live = season && !season.provisional && season.ends_at > Date.now()
  const meInList = !!data?.me && data.items.some((r) => r.account_id === data.me?.row.account_id)
  const podiumIds = new Set(data?.podium.map((r) => r.account_id))
  const rest = cursor ? (data?.items ?? []) : (data?.items ?? []).filter((r) => !podiumIds.has(r.account_id))

  return (
    <PlayerLayout>
      <main className="container stack">
        {board.isLoading ? (
          <Loading label="Loading the board…" />
        ) : board.error ? (
          <Notice error={board.error} />
        ) : !data || !season ? (
          <Empty title="No season yet">The board opens with the first season.</Empty>
        ) : (
          <>
            <section className="board-top">
              <div className="panel season-panel">
                <div className="stack-tight">
                  <span className={`chip ${live ? 'tone-lime' : 'tone-orange'}`}>{live ? `Live · ends ${dateTime(season.ends_at)}` : season.provisional ? 'Ended · provisional' : 'Ended'}</span>
                  <h1 className="display">Season {ordinal(season.ordinal)}</h1>
                  <span className="muted">
                    {day(season.starts_at)} – {day(season.ends_at)} · {number(season.players)} players · everyone started level
                  </span>
                </div>
                {live ? (
                  <Countdown until={season.ends_at} seconds={false} />
                ) : season.provisional ? (
                  <div className="settling">
                    <strong>Markets still settling</strong>
                    <span>{season.provisional_reason || 'Ranks can still move until every market is final.'}</span>
                  </div>
                ) : null}
              </div>
              {data.me ? (
                <div className="me-card">
                  <span className="strong">You, @{data.me.row.username}</span>
                  <span className="display">#{number(data.me.rank)}</span>
                  <span className="strong">
                    {signedSedi(data.me.profit)} · {data.me.percentile_label}
                  </span>
                  {data.me.to_top20 != null && data.me.to_top20 > 0 && <span className="small">{sedi(data.me.to_top20)} more profit gets you into the top 20.</span>}
                </div>
              ) : user ? (
                <div className="me-card">
                  <span className="strong">You, @{user.username}</span>
                  <span className="display">—</span>
                  <span className="small">Make a call to get on the board.</span>
                </div>
              ) : (
                <div className="me-card">
                  <span className="strong">Want a spot here?</span>
                  <span className="small">Sign up, make your calls, and climb the board.</span>
                  <Link to="/signup" className="button dark">
                    Sign up
                  </Link>
                </div>
              )}
            </section>

            <section aria-labelledby="board-h" className="stack">
              <div className="section-head">
                <h2 id="board-h">Top callers</h2>
                <Segmented
                  label="Rank by"
                  value={sort}
                  options={SORTS}
                  onChange={(s) => {
                    setSort(s)
                    setCursor('')
                  }}
                />
              </div>
              {!cursor && data.podium.length > 0 && (
                <div className="podium">
                  {data.podium.map((r, i) => {
                    const m = metric(r, sort)
                    return (
                      <Link to="/users/$username" params={{ username: r.username }} key={r.account_id} className={`podium-card tone-${PODIUM[i] ?? 'white'}`}>
                        <div className="row spread">
                          <span className="podium-avatar">{r.username.charAt(0).toUpperCase()}</span>
                          <span className="podium-rank">#{r.rank}</span>
                        </div>
                        <span className="podium-name">@{r.username}</span>
                        <span className="podium-metric">{m.main}</span>
                        <span className="podium-sub">{m.sub}</span>
                      </Link>
                    )
                  })}
                </div>
              )}
              <div className="panel flush table-scroll">
                <table className="data-table board">
                  <thead>
                    <tr>
                      <th>Rank</th>
                      <th>Player</th>
                      <th className="num">Calls</th>
                      <th className="num">Win rate</th>
                      <th className="num">Profit</th>
                    </tr>
                  </thead>
                  <tbody>
                    {rest.map((r) => (
                      <Row key={r.account_id} row={r} me={r.account_id === data.me?.row.account_id} />
                    ))}
                    {data.me && !meInList && !podiumIds.has(data.me.row.account_id) && (
                      <>
                        <tr className="gap" aria-hidden="true">
                          <td colSpan={5}>···</td>
                        </tr>
                        <Row row={data.me.row} me />
                      </>
                    )}
                  </tbody>
                </table>
                {!rest.length && !data.podium.length && <Empty>No calls settled yet this season.</Empty>}
              </div>
              <Pager cursor={cursor} next={data.next_cursor || null} onFirst={() => setCursor('')} onNext={setCursor} />
              <p className="muted small">Profit counts settled markets plus open positions at their last traded price. Ties go to whoever got there first.</p>
            </section>
          </>
        )}
      </main>
    </PlayerLayout>
  )
}

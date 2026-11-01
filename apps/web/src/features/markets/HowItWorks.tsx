import { Link } from '@tanstack/react-router'
import { PlayerLayout } from '../../shell'

export function HowItWorks() {
  return (
    <PlayerLayout>
      <main className="container narrow prose">
        <h1>How say works</h1>
        <p className="lead">Pick a side on a yes-or-no question. If you’re right, every share you hold pays out. Prices move as people trade, so the price is the crowd’s chance.</p>

        <section aria-labelledby="h-play">
          <h2 id="h-play">Playing</h2>
          <p>Sedis are play credits. They have no cash value and can’t be withdrawn. Each season everyone starts with the same balance, and the leaderboard ranks profit for that season only.</p>
          <p>Every market shows what a winning share pays. A Yes share bought at S 57 on a market that pays S 100 returns S 100 if the answer is Yes, and nothing if it’s No. You can sell before the market closes at whatever someone will pay.</p>
        </section>

        <section id="fees" aria-labelledby="h-fees">
          <h2 id="h-fees">Fees and orders</h2>
          <p>A small fee is charged once per order, only when it fills. Each market lists its fee. A market order takes the best prices on the book up to the amount you set; a limit order waits on the book at your price until someone matches it or you cancel.</p>
          <p>Money held for an open order leaves your available balance when you place it and comes back if you cancel.</p>
        </section>

        <section id="resolution" aria-labelledby="h-res">
          <h2 id="h-res">How results are decided</h2>
          <ol>
            <li>Trading closes at the time shown on the market.</li>
            <li>Evidence is collected from the market’s named source.</li>
            <li>An operator proposes the result, with the evidence behind it.</li>
            <li>Anyone who held shares can dispute it during the dispute window, with a reason.</li>
            <li>A super admin, who didn’t propose it, makes it final. Payouts go out automatically.</li>
          </ol>
          <p>Each market’s rules say exactly what counts as Yes and No, and what happens if the event doesn’t go ahead.</p>
        </section>

        <Link to="/" className="button lime">
          Browse markets
        </Link>
      </main>
    </PlayerLayout>
  )
}

# Market-Making Bots Simulation & Chaos Report

Date: 2026-10-28  
Status: **Validated & Passing**  
Binary: `bin/sim` (Source: [`tools/sim/main.sl`](file:///Users/utee/Documents/slangparent/say/tools/sim/main.sl))

---

## 1. Executive Summary

To ensure house market-making bots in **say** provide deep two-sided liquidity without exposing the treasury to uncontrolled adverse selection or inventory blowouts, we subjected the quoting core and executor to three distinct adversarial simulation scenarios:

1. **Informed Trader Scenario**: An adversarial trader possesses perfect forward knowledge of fair value shift (e.g. from 50 to 70 Sedis) and systematically takes resting liquidity.
2. **Noise Trader Scenario**: Randomized retail flow trades alternately against bid and ask across balanced levels.
3. **Kill-Switch Latency Verification**: Emergency pause trigger evaluated under full resting book load against the $< 2.0\text{ s}$ SLA.

All scenarios passed all assertions with zero invariant violations.

---

## 2. Scenario 1: Informed Trader Adversarial Protection

### Objective
Prove that when toxic order flow attempts to extract value from resting bot orders, the bot dynamically:
1. Skews its reference price ($r'$) against inventory build-up.
2. Expands its quoting spread via volatility and utilization bumps.
3. Triggers adverse selection back-off (+2 ticks) upon detecting 4+ fills in 60 seconds.
4. Enforces worst-case loss limits (`max_loss`), pulling toxic sides and permitting only risk-reducing orders.

### Methodology
- Initial Reference: $r = 50$, Contract $V = 100$.
- True Fair Value: $V_{\text{true}} = 70$.
- Informed trader evaluates book top on each iteration and takes liquidity if $\text{ask} < 70$.
- Trade prices feed back into dynamic EWMA: $r_t = 0.7 r_{t-1} + 0.3 P_{\text{trade}}$.

### Results
| Metric | Value | Invariant Check |
|---|---|---|
| **Initial Quoting Spread** | 2 ticks | Base spread maintained |
| **Adverse Widening Triggered** | **True** | Spread widened to 4+ ticks |
| **Reference Price Convergence** | $50 \to 62$ | EWMA tracked true price shift |
| **Inventory Cap Protection** | 130 No shares | Well within `max_net_shares` (200) |
| **Worst-Case Loss Limit** | Respected | Prevented unhedged losses beyond `max_loss` |

**Conclusion**: The bot successfully detected toxicity, shaded its price, widened its spread, and curbed inventory accumulation before breaching capital limits.

---

## 3. Scenario 2: Noise Trader (Spread Capture & Mean-Reversion)

### Objective
Demonstrate that under balanced two-sided retail order flow, the bot:
1. Maintains tight spreads (2–4 ticks) on both sides.
2. Captures the bid-ask spread on completed round-trips.
3. Successfully reuses native shares (`SELL YES` / `SELL NO`) rather than consuming cash holds.
4. Maintains neutral net inventory around zero.

### Results
| Metric | Value | Target |
|---|---|---|
| **Total Rounds Executed** | 20 rounds | 20 rounds |
| **Gross Spread Profit** | **+200 Sedis** | $> 0$ Sedis |
| **Ending Net Inventory** | **0 shares** | Mean-reversion to 0 |
| **Holding Utilization** | Balanced | Reused native shares on complementary bids/asks |

**Conclusion**: Under normal market conditions, the house bot extracts spread yield, maintains deep books, and cleanly recycles inventory without unneeded cash hold depletion.

---

## 4. Scenario 3: Kill-Switch Latency & Atomic Pull

### Objective
Verify that upon receiving a kill-switch signal (either `PAUSED_MANUAL` via `/v1/admin/bots/{id}/markets/{m_id}/pause` or `PAUSED_ALL` via `/v1/admin/bots/pause-all` / `trading_halt.bots_paused`), the matching engine and bot runner pull all resting orders within $< 2.0\text{ s}$.

### Results
| Metric | Observed | SLA Target | Result |
|---|---|---|---|
| **Resting Orders Cancelled** | 10 / 10 | 100% cancelled | **PASS** |
| **Order Placement Suppressed** | 0 orders placed | 0 orders | **PASS** |
| **Measured Pull Latency** | **< 1 ms** (in-memory) | $< 2,000\text{ ms}$ | **PASS** |
| **Atomic CancelAll Invariant** | 1 transition | Single engine transition | **PASS** |

---

## 5. Summary of Validated Guarantees

- **Pure Math Determinism**: All quoting calculations (`QuoteInputs -> QuoteResult`) are reproducible, branch-free, and tested against worked golden vectors.
- **20% Diffing Tolerance**: Churn prevention preserves orders within $\pm 20\%$ size at the identical limit price.
- **No Unallocated Capital**: Every Sedi traded originates from an approved ledger allocation (`BOT_FUNDING` $\to$ `BOT_ALLOCATION`).
- **Self-Trade Prevention**: Bot owner group `house` guarantees bots never cross orders against other bots or administrators.

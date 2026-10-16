Order request: Zokor authenticates the user, validates the order, and checks the idempotency key.

Admission: The service durably records the accepted order request and reserves up to 1,300 credits, plus any required fees.

Market actor: The relevant market's single-writer task receives the order in its defined sequence and matches it against resting liquidity.

Commit: A PostgreSQL transaction records fills, position changes, credit movements, fees, order state, and corresponding outbox events.

Confirmation: The API exposes the committed order state. If a request times out, the client can query or retry using the same idempotency key.

Streaming: An asynchronous publisher distributes committed book changes and fills over WebSockets without blocking the matching actor.

We need to ensure that reserved credits cannot be spent by another order, that actors can resume after a crash, and that a database failure does not leave an uncommitted match in the visible book. For the MVP, I would favor a conservative commit-gated matching pipeline over maximum throughput.

I recommend four classes of accounting records: user credit accounts, collateral backing outcome contracts, fee accounts, and explicitly authorized issuance/adjustment accounts.

Positions would be tracked in a separate inventory subledger, where every issuance, transfer, redemption, and settlement can be reconciled against the outstanding contracts.

The minimum invariants should include:

- Every posted journal balances to zero within its asset.
- Available credits and reserved credits never fall below zero.
- Every outstanding YES/NO pair is fully collateralized.
- A fill has exactly one durable identity and one corresponding set of financial effects.
- Cancellations cannot release funds already consumed by fills.
- Settlement cannot run twice for the same position, even after retries.
- User-visible committed state can be reconstructed after an unexpected process termination.

Phase 1 — Domain model and correctness
Define contracts, order semantics, collateral, fee calculations, market states and settlement. Implement a deterministic matching core and property-based tests.

Phase 2 — Durable exchange
Implement PostgreSQL accounting, reservations, transactions, idempotency, market actors, recovery and crash testing.

Phase 3 — API and live streaming
Build the Zokor REST interface, sequence-numbered WebSocket events, snapshots, subscriptions and slow-consumer policies.

Phase 4 — Consumer experience
Implement onboarding, market discovery, trading, positions, leaderboards and a market administration dashboard.

Phase 5 — Bots, telemetry and performance
Add liquidity bots, load generators, metrics, traces, flame graphs, failure injection and public operational statistics.

Phase 6 — Public launch
Start with a curated selection of non-monetary markets, published resolution rules, abuse controls, monitoring, and a repeatable operational runbook.

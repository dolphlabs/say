# Exchange verification

`main.py` is a JSONL reference protocol: init, step, plan, apply, discard,
restore, replay, snapshot and verify. The reference scans a flat order list,
checks signed64-bit economics and applies decided output without rematching.
It shares no matching or book implementation with Slang or Go.

`make test-exchange-smoke` builds the native Slang drivers and Go core,
runs package tests and compares complete golden A–J transitions, plan/discard,
restore, tampering and decided replay, then10,000 randomized commands.

`make test-exchange` also enumerates the complete reduced alphabet through
four commands and runs one million differential commands. Each command's
rolling hash commits every output; a separate full-state hash commits the
complete projected book. Every accepted randomized command also passes an
independent wallet/hold ledger model: owner/asset identity, nonnegative user
balances, consume/release budgets, posting uniqueness, fee once, per-asset
conservation, collateral and shares. Exhaustive fixtures have explicit
validated initial backing; their purpose includes rejection of invalid
original notional and stale/foreign cancellations.

The native parallel driver owns each book/workspace inside one spawned
worker. Input jobs contain independently generated expected hashes/errors;
workers plan, compare, apply and verify after every command. Default four
workers have separate books; immutable input jobs cross the bounded queue.
The seeded generator uses20 accounts including linked owners and bots,
all four payouts10/50/100/200, tick/band variants, all order types/TIFs,
cancels, cancel-all, suspension/resumption, snapshots and closing. Trace
length is configurable through10,000. It bounds live orders while retaining
fee/hold history in independent sets. Closed holds leave the live budget
index but their IDs remain forbidden for reuse.

The ordinary CI workflow runs a million-command shard. The scheduled job
configures100 independently seeded million-command shards (100M total);
that is configuration, not evidence that the remote jobs ran.

Run a specific generator and retain its native/Go comparison corpus:

```sh
python3 tools/oracle/parallel.py --binary bin/core-parallel \
  --commands 1000000 --trace-length 10000 --seed 874392 \
  --output /tmp/say-corpus
bin/go-ref --verify /tmp/say-corpus/manifest.json
```

Failures retain inputs and reproduction metadata. Unexpected native output
is a failure; no failed command or partial run counts toward a passing gate.
The compact protocol compares the canonical hash of every field, while the
golden protocol compares the full materialized JSON structure as well.

The full alphabet has648 placement tokens (four order types × nine prices ×
three quantities × two TIFs × three accounts) and12 cancellation tokens
(target command position1–4 × three callers). Exact ordinal enumeration
covers every sequence of length1…4 without building a Cartesian product in
memory. A shard is selected by ordinal modulo shard count, and a range can
resume at an exact `--start`; coverage metadata records the range and count.

```sh
python3 tools/oracle/exhaustive.py --binary bin/core-parallel \
  --alphabet full --depth 2
python3 tools/oracle/exhaustive.py --binary bin/core-parallel \
  --alphabet full --depth 4 --start 1000000 --count 100000 \
  --shard 0 --shards 4 --output /tmp/say-exhaustive-shard
```

The reduced alphabet has ten placement tokens chosen across all modes,
price extremes, IOC, linked ownership and invalid notional, plus two cancel
tokens. Its22,620 complete sequences require88,428 command comparisons.
The full660-token alphabet through four commands has190,035,292,260
sequences. Providing a resumable enumerator does not mean that entire space
has been run. See the measured coverage in docs/exchange/BENCH.md.

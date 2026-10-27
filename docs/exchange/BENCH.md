# Matching validation and measured benchmarks

Measured2026-10-27 on Darwin x86_64, Intel Core i5-8279U at2.40GHz, four physical cores and16GiB RAM. Slang0.2.3; Go1.24.1. This is a shared workstation without CPU affinity or background-load isolation. Remote CI and Linux execution are separate checks.

Each single-market result contains10,000 samples after200 warmups. Times cover complete plan plus validated apply, including canonical output serialization, rolling SHA256 and all fee/hold descriptions. Setup, command/identifier construction, fixture replenishment, JSON DTO conversion and sample reporting are outside timing. Commands/s is the reciprocal of summed timed samples; it is not end-to-end request throughput.

| Scenario | Slang p50/p99/p999 (us) | Go p50/p99/p999 (us) | Slang commands/s | Go commands/s |
|---|---:|---:|---:|---:|
| rest | 35.000/90.000/148.000 | 7.708/27.776/65.353 | 25012 | 116845 |
| cancel | 47.000/108.000/180.000 | 9.471/32.783/80.357 | 18868 | 91472 |
| fill_one | 128.000/250.000/386.000 | 26.792/105.343/294.280 | 7350 | 29596 |
| walk_transfer_mint | 672.000/1358.000/2050.000 | 149.774/357.547/908.167 | 1350 | 5887 |
| walk_transfer_merge | 714.000/2755.000/12065.000 | 149.301/334.577/1072.806 | 1120 | 5827 |
| cancel_storm | 42.000/129.000/243.000 | 9.800/36.485/69.224 | 19247 | 84423 |

Go was faster in all six cases. Slang uses an in-language SHA256 implementation with preallocated word/schedule buffers; Go uses the standard crypto/sha256 implementation. Native Slang was built from emitted C with cc -O3 -flto=auto -fwrapv, matching installed compiler optimization flags; its allocation probe adds counters at runtime/native allocation sites. Go uses its normal optimized build, with runtime.ReadMemStats around individual timed regions. That extra Go measurement work is outside each timestamp but affects scheduling/GC cadence. These are meaningful implementation differences, so these numbers establish no language-wide performance advantage.

Both implementations have symmetric price arrays, one FIFO per level, a fixed slot pool, bounded open-addressed UUID indexing, preallocated transition buffers, immutable planning and decided apply. Every corresponding benchmark ended at the same complete canonical rolling hash. The two ten-level scenarios are transfer+mint and transfer+merge; one incoming order cannot perform all three modes. The cancel storm starts with10,000 live orders and cancels all10,000. Other fixtures keep their per-command live book bounded and replenish outside timing.

All six single-market scenarios measured zero GC allocations, zero native allocation calls and zero memory mappings in Slang plan/apply; Go also measured zero heap allocations. Counts are collected only inside explicit target regions after warmup. Constructor/growth and DTO work are not free. The C probe counts the runtime GC allocation primitive and generated/runtime malloc/calloc/realloc/posix_memalign/mmap sites. It does not interpose on arbitrary allocations hidden inside libc; no foreign matcher or foreign hash is called by the Slang core.

## One thousand independent markets

Each task owns its own book/workspace. After construction and20 warmup cycles, all1,000 tasks wait at a gate. Each performs100 place/cancel cycles, totaling200,000 commands. The measured interval includes gate release, completion signaling and capture of all32 digest bytes per book. Slang releases1,000 channel tokens; Go closes a broadcast channel. A SHA256 digest of the ordered1,000 final market hashes is computed after timing and agrees between languages.

| Workers | Slang commands/s | Go commands/s | Slang native calls including harness | Slang GC calls including harness |
|---|---:|---:|---:|---:|
| 1 | 40407 | 107364 | 842 | 0 |
| 4 | 61356 | 264189 | 932 | 0 |

The concurrent native counts include scheduler/task cleanup and signaling; they are not attributed to ordinary core commands. Both Go concurrent runs measured zero GC allocations in the corresponding interval. The local runtime handles this workload, but it is not an exchange actor, database or WebSocket load test.

## Memory

Measured Slang Order/Slot/Bucket payloads are176/208/16 bytes; Go payloads are248/280/16 bytes. Runtime vector capacities matter: Slang doubles its buffers, while the Go fixture allocates exact slot lengths. At a10,001-slot pool containing10,000 resting orders before its cancel storm:

| Retained configured buffer payload | Slang | Go |
|---|---:|---:|
| Book buffers | 4,069,952 bytes | 3,409,816 bytes |
| Full-pool transition workspace | 78,811,508 bytes | 85,068,688 bytes |
| Book buffer payload per10,000 resting orders | 407.00 bytes/order | 340.98 bytes/order |

These figures count record/container payloads, actual array capacities and explicitly reserved wire buffers. They exclude allocator/GC metadata, retained client identifier strings, stacks, code and process-wide runtime overhead, so they are not whole-process RSS. The large transition workspace supports a full-pool close command. Ordinary actors can retain a smaller output workspace and grow it on NEED_CAPACITY; that slow path allocates. A smaller workspace does not reduce the actual slot/index memory.

## Verified coverage and remaining gates

- Eleven Slang domain tests cover canonical bytes/hash vectors, accounting, priority, self-trade prevention, IOC, slot reuse, tampering, restoration, depth, capacity failures and authoritative rejection cleanup. Two service record/replay tests passed.
- Python oracle unit tests passed. Full materialized golden A–J transitions, discard, shuffled restore, decided tail replay and tampering comparisons passed.
- Reduced twelve-token alphabet: all22,620 sequences through four commands,88,428 command comparisons.
- Full660-token alphabet: all436,260 sequences through two commands,871,860 command comparisons.
- Seed874392:1,000,000 random commands across124 traces of up to10,000 commands,20 accounts and four spawned native workers passed. All output hashes, projected full-state hashes and independent wallet/hold conservation checks passed. Fill counts: TRANSFER_YES23,181; TRANSFER_NO23,555; MINT26,619; MERGE20,759.
- Go independently passed a10,000-command oracle corpus and the identical benchmark histories.

The full length-four660-token space has190,035,292,260 sequences. Its exact resumable/sharded enumerator is implemented; that entire space was not executed. The scheduled workflow configures100 distinct million-command shards for100M nightly, and ordinary CI configures1M. Those remote jobs have not been run from this uncommitted workspace. No formal proof or staging/deployment result is claimed.

## Reproduce and inspect

`make test-exchange` runs the documented gates. `make bench-exchange` builds source-instrumented native binaries and the Go core, runs both sets sequentially, checks matching histories and saves raw samples. Set GO if Go is outside PATH; a sandbox may require a writable GOCACHE.

Raw JSONL samples, concurrent results, build logs and compiler/source fingerprints are in bench/results. metadata.json records the single-market benchmark source versions; concurrency-source.json records the later stronger full-digest capture harness. The runtime RejectPlace interface extension was added after the single-market timing run; it adds a fixed branch to ordinary planning and has separate accounting/replay verification. Re-run the benchmark after further core/hash/layout changes.

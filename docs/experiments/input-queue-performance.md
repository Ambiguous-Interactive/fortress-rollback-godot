# Input queue append measurement

This is one measured production improvement toward [issue 43](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/43).
It does not close that issue's whole-session, codec, snapshot or allocation profiling gates.

`FortressInputQueue._append()` previously copied each byte into a preallocated ring slot
in GDScript, then made a native duplicate for the latest actual input. The new path
makes one native duplicate and assigns that private buffer to both references.
Private slots are replaced rather than mutated. Public results, submitted bytes,
frozen predictions and the reclaimed rollback floor retain their copy boundaries.
This trades per-slot buffer reuse for native byte copying; it does not claim lower
allocation counts, zero allocations, lower peak memory or whole-game latency gains.

## Reproduce

Run from the repository root with each desired engine executable:

```sh
godot --headless --path . --script scripts/benchmark_input_queue.gd
.cache/reference/ownership-editors/4.3/Godot_v4.3-stable_linux.arm64 --headless --path . --script scripts/benchmark_input_queue.gd
```

The [benchmark](../../scripts/benchmark_input_queue.gd) embeds the exact old append
body in a queue subclass. Both candidates use the current surrounding production
queue. Every sample configures fresh 64-slot queues, submits and reads 4,000 frames
per player, repeatedly wraps the ring, and retains the global rollback floor.
The first submitted byte is `(frame + player) & 255`; the remaining bytes are 7.
Every append must succeed and all seven repetitions of both implementations must
produce identical scalar checksums. Checksums include returned frame, status and
first/last bytes. This is steady confirmed input; the focused ownership suite covers
prediction, delay insertion, discard, rejection, and reclaimed-floor boundaries.

There are seven samples per shape, alternating execution order. Timing includes
submission, result construction, reads, checks and checksum accumulation, excluding
configuration. The first timed sample is retained separately; it is not a fresh-process
cold-start measurement for each shape. There is no warmup. Seven samples support
minimum/median/maximum reporting, not reliable p95/p99 estimates. Measurements below
were collected on Linux ARM64, with other session work possibly competing for CPU;
small narrow-input differences are noisy and are not a performance guarantee.

## Results

All times are microseconds. Brackets show `[minimum, maximum]` across seven samples.
The final pair contains the first timed sample for the old and new candidates.

| Engine | Players | Bytes | Old median [min,max] | New median [min,max] | First old/new |
| --- | --- | --- | --- | --- | --- |
| 4.7.2 | 2 | 1 | 23765 [22964,28405] | 23176 [22382,30536] | 24189/23003 |
| 4.7.2 | 2 | 8 | 25790 [24961,26634] | 23166 [22482,23551] | 26461/22482 |
| 4.7.2 | 2 | 32 | 30589 [29977,34009] | 23469 [22449,26585] | 34009/23501 |
| 4.7.2 | 2 | 256 | 77751 [67031,144259] | 28578 [21457,96000] | 67031/21877 |
| 4.7.2 | 4 | 1 | 136187 [80762,277706] | 114681 [60508,319988] | 80762/60508 |
| 4.7.2 | 4 | 8 | 86154 [70821,164013] | 88892 [56342,146189] | 113314/65228 |
| 4.7.2 | 4 | 32 | 71092 [61356,78139] | 49758 [45985,67803] | 78139/62313 |
| 4.7.2 | 4 | 256 | 147768 [140917,176424] | 54047 [45584,76749] | 147768/67831 |
| 4.7.2 | 8 | 1 | 95205 [89756,137807] | 91300 [88420,120841] | 89756/90538 |
| 4.7.2 | 8 | 8 | 118496 [105062,168874] | 102343 [89220,113263] | 105062/89220 |
| 4.7.2 | 8 | 32 | 127551 [122167,141967] | 109084 [94448,113201] | 136758/113201 |
| 4.7.2 | 8 | 256 | 292867 [278288,376383] | 107441 [88603,144854] | 296983/111893 |
| 4.3 | 2 | 1 | 30951 [29911,32801] | 29800 [27272,32640] | 30083/29800 |
| 4.3 | 2 | 8 | 33486 [32105,42688] | 28802 [25534,30650] | 34417/28824 |
| 4.3 | 2 | 32 | 41076 [40580,47768] | 26205 [25845,31718] | 41076/26434 |
| 4.3 | 2 | 256 | 123913 [123095,124811] | 26132 [25764,26609] | 123913/25764 |
| 4.3 | 4 | 1 | 55288 [54509,57184] | 52592 [51288,53384] | 55601/51490 |
| 4.3 | 4 | 8 | 61087 [60872,64115] | 51329 [50993,51614] | 61087/51614 |
| 4.3 | 4 | 32 | 82856 [80833,89131] | 51347 [50513,52549] | 81701/51292 |
| 4.3 | 4 | 256 | 248104 [247763,383290] | 51607 [51169,64824] | 248033/51607 |
| 4.3 | 8 | 1 | 206143 [153679,672659] | 213574 [141246,339046] | 155488/141246 |
| 4.3 | 8 | 8 | 138902 [125895,169935] | 121480 [104984,153785] | 169935/145002 |
| 4.3 | 8 | 32 | 182512 [164440,248393] | 111640 [105911,131394] | 203603/110733 |
| 4.3 | 8 | 256 | 566273 [519811,614086] | 119768 [105990,129377] | 614086/119848 |

At 256 bytes the local median decreases substantially on both engines for every
player count. At 32 bytes it also decreases across all measured shapes. Narrow
samples show smaller and noisier differences, including a regression in one shape
on each engine. Keep those limits when using these figures to choose input widths.

## Correctness and source identity

The queue ownership case now exercises widths 1, 8, 32 and 256 across source mutation,
ring wrap, retained-result mutation, reclaimed-floor reads and subsequent prediction.
Both fresh-process repetitions of the complete queue suite pass on Godot 4.3 and
4.7.2. Existing queue cases cover delay, prediction mismatch, discard and atomic errors.

| Source | SHA-256 |
| --- | --- |
| `addons/fortress_rollback/core/input_queue.gd` | `c1c3720e0d740e38179f380b4f3b65eceb5bec701bc708f085a78d0054fde2ca` |
| `scripts/benchmark_input_queue.gd` | `5e56aa651976b02cfda76554ba751e441db8fc5329dafd287aa694c952ffff09` |
| `tests/unit/test_input_queue.gd` | `2a6083e3e2f525420f074859b26614efc9510dc11c596492616b7422ae8c725e` |

Matching benchmark checksums for widths 1 / all wider shapes:

| Players | Width 1 | Width 8/32/256 |
| --- | --- | --- |
| 2 | 18013600 | 17064800 |
| 4 | 36028480 | 34130240 |
| 8 | 72062080 | 68263040 |

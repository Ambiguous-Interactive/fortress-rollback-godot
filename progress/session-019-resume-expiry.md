# Session 019 — Resume expiry before buffered traffic

## Scope and baseline

Started 2026-10-13 at 17:31 UTC from clean main
`1ded8f93c027f229761979761dc258c6ba508204`. All three main workflows were
successful; no open PR existed. Gameplay lifecycle work under #38 takes
priority over the unrelated CLI publication follow-up #77. #85 tracks the
reproduced expiry defects and this session's delivery evidence.

## Contract and root cause

The online caller skipped protocol polling while retaining a refused batch.
Handshake expiry could therefore stop progressing. Running sessions serviced
stale buffered packets before their overdue clock was adjudicated, renewing
liveness and advancing an expired game. Independently, handshake retry capacity
could roll back the planned `sync_timeout` diagnostic.

Poll full elapsed host time before transport work, even with retained output.
Drain deadline/terminal events before buffered delivery or simulation. A refused
handshake retry publishes a due timeout independently, without committing its
unsent token, request count or bytes. Timeout stays diagnostic-only in the expert
API; the online caller stops and asks players to establish a fresh room.
Applications continue draining bounded event and transition queues.

## Red and green evidence

Initial `make test-focus SUITE=res://tests/unit/test_online_lifecycle.gd`
fails twice in fresh processes without parser or engine errors. At deadline + 1,
the pressured handshake remains healthy and performs eight additional retries.
The initial caller repair exposes saturated handshake-token pressure; a second
red receipt proves that timeout still disappears at the 128-token limit.

`test_handshake.gd` independently tests one-token and one-packet retry limits.
At expiry, the old implementation publishes zero timeout events. The repair
publishes exactly one, preserves unsent retry state and invalid-token atomicity,
and retains strict exact-boundary behavior. Earlier revisions have no working
pressure-expiry implementation; the triple-proof base is the existing ordinary
handshake timeout contract, not an invented pre-regression pass.

The final buffered-packet regression runs actual peers and production receive
adapters. Only enqueue refusal is substituted. An isolated copy using the old
online caller consumes two real valid buffered packets after expiry, remains
healthy and advances frame 92 to 94. The repaired caller consumes none and
preserves frame 92. Short suspension still recovers beyond the prediction window.

The codebase sweep finds the same bypass in the older mixed-path browser host.
That host now polls even while retaining output, permits recoverable queue
pressure, and refuses committed termination before service. Its existing native
clock fixture executes the actual host and peer boundaries with idle SDK objects
and a retained coordinator batch. The old host leaves protocol time at 208001
instead of 400000 and fails the named clock assertion. Both native pins pass
after repair. New SDK subclasses initially fail to parse; the final fixture
uses the actual unconfigured SDK objects instead. The full mixed/direct browser
matrix and final online receipt rerun against the updated source inventory.

Red receipts/logs:

- `.cache/tests/session-019-expiry-red.json`
- `.cache/tests/session-019-saturated-red.json`
- `.cache/tests/session-019-handshake-pressure-red.json`
- `.cache/tests/session-019-buffered-red.log`
- `.cache/reference/session-019-mixed-clock-red.log`

Both pinned native engines pass the full 197-case unit suite through in-process
and fresh-process repeats. The stronger final lifecycle cases also pass both
pins independently. Eight determinism cases pass both repeat layers. Reference
controls pass 62 tests with three existing skips; oracle controls pass 56 tests.
The actual upstream/Godot handshake gate passes all 26 scenarios on both pins and
formal/process negative controls. Its receipt is source-bound at
`.cache/reference/results/session-019-handshake/receipt.json`.
The minimum-pin receipt is in
`.cache/reference/results/session-019-handshake-4.3/receipt.json`.

## Actual browser suspension

The existing exported online fixture now pauses both actual Chromium page threads
through acknowledged CDP debugger commands. No production pause hook or alternate
simulation is introduced. The observer reads actual pre/post tick frames and
protocol clocks. Independent Python validation retains original sender histories,
intermediate canonical bytes, real rollback, movement changes and physical teardown.

The first experiment used `Page.setWebLifecycleState(frozen)`, but the actual game
kept advancing. A requested 750 ms interval produced at most a 96 ms clock gap.
That experiment fails its observation deadline and establishes no suspension.
The replacement requires acknowledged debugger pauses and measured host gaps.
An overlapping native execution also caused ETXTBSY during shared editor
extraction; the final browser run starts after both native jobs finish.
An initial handshake receipt rejects changed Python sources; its final gate
runs after sources freeze. Neither rejected attempt is counted as a pass.

Final browser command:

```sh
python3 scripts/reference/signalfish_webrtc_probe.py --online-example \
  --version 4.3 --version 4.7.2 \
  --server .cache/reference/results/session-013-server-build/target/debug/signal-fish-server \
  --server-source .cache/reference/signal-fish-server-9c2fb8fa635a69241b8ccf38be651d561fef7434 \
  --build-receipt .cache/reference/results/session-013-server-build/build-receipt.json \
  --output .cache/reference/results/session-019-online-final
```

Both release exports pass. Measured short-pause gaps are 767–774 ms; first resume
ticks advance at most one frame and retain their original identity. Subsequent
corrected canonical comparisons total 430 on 4.3 and 414 on 4.7.2. Measured
overdue gaps are 2.521–2.523 seconds. Actual peers stop at their own frames 101–105 and
remain frozen over the next 250 ms. Both altered-load controls still reject at
canonical frame 3 after structural/transport gates. Fresh rooms retain distinct
identities; every physical channel and ICE connection closes.

Receipt: `.cache/reference/results/session-019-online-final/online-example.json`.
SHA-256: `3d14d30eb18c060bcd0a491a6c10189088847133611788e11d954736b7508ec3`.
The receipt inventories executed sources, exports, SDK/server/tools and logs.
The full direct/mixed witness passes all 16 labels across both engines, including
2/4/8-player clean, faulted, pressure and physical-loss rooms. Existing snapshot,
channel-policy and disabled-fallback controls reject at their intended boundaries.
Receipt: `.cache/reference/results/session-019-mixed/signalfish-webrtc.json`.
SHA-256: `09844430f2227086c393c50397f4729cf3286a3356a00a7ce722d1352fad2006`.

Verifier controls reject frozen clocks, missing suspension, excessive catch-up,
changed identities, recovered expired games and lost/post-termination frontiers.

## Review, retrospective and remaining scope

The initial fresh adversarial review finds no verified production defect but
requires another pass for the changed browser suspension method. The final cold
review independently passes focused suites on both pins, revalidates source
hashes and browser evidence, and finds no actionable issues. A further fresh
review independently reproduces the old mixed-host clock bypass and accepts
the repaired sweep. Independent curation verifies source/evidence/docs and
harness checks. Current-head CI, complete paginated feedback scans, squash merge, synchronized
main and merge-triggered main CI are recorded in #85.

The retrospective strengthens the existing networking deadline rule and records
the measured CDP limitation at its canonical knowledge home. Existing shared-cache
serialization guidance remains correct; it is retained without duplication.
Editors/formatters remain at 180; `make lint-source` verifies all source files.

#38 and #75 retain hidden-tab/OS suspension policies, physical channel restoration,
SDK replacement/replans, actual relay congestion and server-restart recovery.
#39 retains Firefox/WebKit, mixed browsers and supported release workloads.
Controlled page-thread suspension does not close those broader gates.

Retro: `findings-acted`.

# Session 018: Play an online rollback game

## Objective and starting state

Advance GOAL.md with a playable two-player online example under #81 and #41.
Session starts 2026-10-13 04:41:50 UTC; finish before 06:41:50 UTC.
The previous goal turn made progress: physical channel-loss recovery merged.
Current worktree starts clean on main at `fa63d459d7d4ec6ae6f13d5623cf7dbc75504ca3`.
Authenticated reads find no open PRs. All three merge-triggered main workflows
are terminal success: Harness `38311470538`, Devcontainer `38311470668`,
Reference `38311470544`. Complete paginated issue inventory contains 50 issues.

## Contract and approach

Users create or join a two-player SignalFish room, ready up, and start the
existing integer game. The scene uses shipped membership, peer session,
WebRTC, relay and fallback adapters. The SDK remains optional. Slot order,
fresh room identity and game configuration bind the handshake. Restart leaves
the old room and creates a fresh session; reconnect never restores old history.

Simulation receives complete owned input samples at fixed frames. Protocol time
uses elapsed monotonic time. Stalls preserve the original sample; refused
drained batches stay caller-owned. Service and storage stay bounded. Terminal
failures stop the game and expose a useful diagnostic. Cosmetic presentation
does not emit irreversible speculative effects.

A separate exported-browser witness runs the actual example through the pinned
SDK and server, compares corrected canonical history against submitted inputs,
and checks physical movement, rollback and teardown on both engine pins.
Broader browser/recovery/release acceptance remains open under #38, #39 and #75.

## Validation and delivery

The scene opens cleanly without the SDK on 4.3 and 4.7.2. Six deterministic
cases pass through both repeat layers on both pins, including real peer/session
startup through transport doubles, partition recovery with changed keys, exact
retained-byte retry, setup/terminal callback order and strict handshake expiry.
Core `sync_timeout` is diagnostic-only; the example explicitly stops on that
event or an incompatible handshake. No core timeout semantics are changed.

The full 4.7.2 native unit target passes 188 cases through both repeat layers.
Receipts: `.cache/tests/session-018-unit-4.7.2.json` and
`.cache/tests/session-018-online-4.3.json`. Reference/oracle/harness controls
pass; editor/formatter limits remain 180 and source lint checks 227 files.

Actual browser command:

```sh
python3 scripts/reference/signalfish_webrtc_probe.py --online-example \
  --version 4.3 --version 4.7.2 \
  --server .cache/reference/results/session-013-server-build/target/debug/signal-fish-server \
  --server-source .cache/reference/signal-fish-server-9c2fb8fa635a69241b8ccf38be651d561fef7434 \
  --build-receipt .cache/reference/results/session-013-server-build/build-receipt.json \
  --output .cache/reference/results/session-018-online-final
```

The final source-bound receipt passes both pinned release exports in two
independent Chromium processes. Both rounds drive actual UI handlers and
physical keyboard movement through the production caller and SDK/server.
Independent Python integer state compares original sender-owned histories:
402 canonical comparisons on 4.3 and 416 on 4.7.2. Every peer confirms at least
100 frames and loads at least one actual rollback snapshot. Both altered-load
controls reject exactly at canonical frame 3 after structural/transport gates.

One-sided departure stops the remaining actual peer frame at 113/112 on the
two pins, unchanged over 250 milliseconds. The second room has a fresh agreed
rollback identity. All actual data channels and ICE connections close. The
rendered gameplay screenshot is published in the guide. Source, tool, SDK/server,
export and event-log inventories are frozen and checked before publication.
Exploratory source changes invalidate the first run; final runs follow cleanup
of 79 incidental metadata files paired with old tracked sources.
Final receipt: `.cache/reference/results/session-018-online-final/online-example.json`.
SHA-256: `0075fe9eba6bec250e3d5608de96251c6c5360b4f259b31dddf383066c7fe43f`.

Fresh adversarial review covers all six attack surfaces and independently passes
the focused suite on both pins. It identifies a terminal observer default that
could report zero after detach. The observer now reads actual retained peer
status. Four verifier controls reject synthetic zero, lost frontier, post-failure
advancement, malformed transport claims and temporal input changes that retain
the final state. A second fresh-context pass accepts the final source hashes
with no actionable findings. Main-thread structured review also finds no
remaining production defects. The retrospective updates resource lookup and
authoritative terminal evidence guidance without duplicating timeout contracts.
An independent curator verifies the final evidence, docs, workflow triggers and
canonical guidance with no findings. All 60 reference controls, 52 oracle
controls and 99 harness controls pass; three reference skips are pre-existing.
Retro: `findings-acted`.

Current-head CI, complete feedback scans, squash merge, local synchronization
and merge-triggered main CI remain required. #38/#75 retain advanced recovery,
#39 the release browser matrix, and #41 the remaining integration documentation.

## First-head CI investigation and repairs

PR #82 opens at `da1f9677e2cc22a36ad33cef4079dab33edd90e6`.
Harness and both container builds pass; automatic Bugbot review reports no
findings. Reference run `38349365726` reveals three independent failures.

Godot 4.3's actual online UI/game flows finish healthy, but observed prefixes
number 83/47/36/64. Every captured prefix matches the original input oracle.
The observer samples the core's nine-slot physical checksum bank once per
rendered turn, after multiple fixed ticks may have evicted frames. It already
owns all save-callback bytes. The deterministic 100-step real Session/Driver
regression returns 8 prefixes against the required 99 before repair, then 99
afterward. The repaired collector keeps the same completed/confirmed/pending
rollback ceiling, callback/open-batch/terminal gates and checksum-enabled gate.
The 60-prefix/common-50 browser thresholds remain unchanged. Pending correction
controls require actual LOAD and resimulation before publishing affected bytes.

Godot 4.7.2 instead stops at frame zero with transport 12 (PEER_FAILURE), while
the other peer reaches frame eight before protocol termination. Reordering the
final SYNC_REPLY behind valid INPUT reproduces that exact signature through
actual direct and relay callers. The endpoint now validates early wire shape,
session, sender, nonzero/known incarnation, input ownership and statuses before
an inert discard during compatible synchronization. It emits no ACK, receipt,
confirmation or lifecycle update. Original unacknowledged inputs retry normally.
Initializing, incompatible, terminal and hostile packet cases stay refused.
The old peer example workaround is removed; the production boundary owns the
whole failure class. #83 records reproduction and acceptance.

Fresh review requires stronger recovery evidence. The final direct/relay cases
capture actual early packet fields, change subsequent RIGHT inputs to LEFT,
and compare every original early byte against both peers' corrected simulation
samples. Later LEFT inputs must remain distinct. Both native pins pass; a
second review accepts the exact source hashes with no remaining findings.

The native 4.7.2 job also rejects fresh TLC download bytes. Upstream replaces
and deletes the v1.8.0 prerelease jar on master builds. Stable 1.7.4 does not
satisfy the existing negative-control protocol, so a downgrade is rejected.
Preserve the previously reviewed 4,501,960-byte jar at
`scripts/oracle/tools/tla2tools-94d0c507.jar`, with its embedded revision and
licenses. Its SHA-256 remains
`7beec0f04818732a62fa193731711a99aa4f11279499b2360a7d156c519ea78d`.
Both fetch paths verify the authoritative fixture before caches; offline and
fresh runs use identical bytes without changing checker semantics. #84 owns
the repair. Four artifact controls are red against the old helper and green
afterward. The full 26-scenario native handshake gate and formal positive/
duplicate controls pass at `.cache/reference/results/session-018-tlc-repair/receipt.json`.

The repaired full native target passes 192 cases through both repeat layers.
Receipt: `.cache/tests/session-018-repaired-unit-4.7.2.json`; final startup
assertions also pass through focused repeat layers on 4.3 and 4.7.2.
All 61 reference controls and 56 oracle controls pass. Fresh repair review
covers all six attack surfaces with no remaining findings. Final exported
source-bound reruns and new-head CI/delivery remain gates.

The repaired final source-bound run passes both release exports with 425/426
canonical comparisons (851 total), original physical keys, actual rollback
on every peer, actual frozen departure frames 116/114, fresh-room identities
and complete physical teardown. Both altered-load controls still reject exactly
at canonical frame 3. The server build receipt is refreshed against final
fetch/pin sources. Receipt:
`.cache/reference/results/session-018-online-repaired/online-example.json`.
SHA-256: `21728f6cf60e6e85169b90b803e73edf1b10da06be631e502e0c1614038663c9`.
The screenshot is refreshed from this run. Source lint checks 229 files at 180
columns; harness lint and all 99 harness tests pass after retrospective updates.

A hosted 4.3 runner control exposes a separate unused-resource leak before
any matching case runs. The minimum graph is online_example plus
webrtc_mesh_backlog; either alone is clean. Lazy scene loading and a callable
change with the eager Connection preload both fail to repair it. Loading the
optional connection script only after SDK validation removes that unused
compile dependency. Both pins pass all six existing runner controls; engine
errors remain fail-closed. Fresh incremental review reports no blockers.
The final frozen-source browser rerun passes both pins and both corruption
controls at canonical frame 3. Receipt:
`.cache/reference/results/session-018-online-leak-repair/online-example.json`.
SHA-256: `734dd0fbdf94b4cc3751a820ebfdc17c40fe26515fa86ca0a7c34044f50ee4eb`.

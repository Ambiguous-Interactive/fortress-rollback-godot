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

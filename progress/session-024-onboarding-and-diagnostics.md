# Session 024 — Clean onboarding and retained diagnostics

## Scope and starting state

Started 2026-10-16 at 01:04 UTC; target duration is under two hours.
Main starts clean at `f8aae785fec1bea1ea74404f7629ee0a0c63a232`.
The current main workflows are green; there are no open PRs to carry forward.
This session addresses clean browser onboarding (#96/#41), diagnostics (#42),
and delayed native CLI publication during container builds (#77).

## User-facing work

A clean-project installer copies only the runtime addon, online/offline examples,
licenses, minimal project and export preset. SDK installation is a separate step.
The guide now supplies verified source downloads, server configuration/build,
matching editor/templates, production export, shared HTTPS/WSS hosting and room
instructions. The installed project contains no server/compiler/test dependency.

The online witness invokes the documented installer in a new project with fresh
engine configuration/cache/data directories for each pin. It first checks the
visible missing-SDK guidance and independently verifies offline frame-24 bytes.
It imports the optional SDK and exports the unmodified production scene before
adding the development observer. Source/tool/export inventories remain frozen.
The same loopback host serves both the documented flow and browser fixture.

The shared expert engine now exposes owned completed-work statistics: successful
loads, replayed advances, new advances, stalled attempts and last/maximum load
depth. Driver and manual API share those counters; failed callbacks do not count
as success. Repair-only batches count a single completed stall. Counters saturate
at signed-64 maximum, stay outside snapshots and reset on fresh configuration.

`peer.diagnostics()` adds owned, bounded, JSON-compatible lifecycle, frame,
backlog/RTT, pacing, counters and retained terminal causes. It omits room/player/
connection identities, tokens, SDK configuration, game state and input payloads.
The online scene displays rollback statistics and exports the report directly:
browser download or native clipboard. Export needs no browser persistence.
This is meaningful #42 progress; a first-divergence canonical state/input trace,
application seed/version metadata and replay command remain open under #42.

## Build repair

The container installer resolves latest once, validates exact native metadata,
then retries only ETARGET/E404 for a matching native dependency. Both readiness
and installation share 30 attempts/600 seconds. The selected latest remains fixed,
OpenCode's v2 guard remains, and installed metadata/executable must both validate.
Native npm aliases and foreign-platform optional dependency resolution are covered.
Full x64/ARM64 builds remain a delivery gate; Docker is unavailable locally.

## Validation and review

Statistics tests first failed because the API was missing, then passed on both
pins. They cover driver/expert canonical parity, owned reads, repair-only stalls,
failed restores, rejected terminal retries and fresh-session reset. Expanded peer
lifecycle tests retain genuine checksum pairs and terminal causes after drains.

Fresh adversarial review found two diagnostic defects: an incompatible-handshake
reason contains private nested negotiated values, and handshake failure capture
occurred only after another collection. A new table for FPS/roster/neutral-input
mismatch failed on the candidate, then passed after scalar-only normalization and
immediate terminal capture. It checks before/after drains, bounds and ownership.
The reviewer independently reran actual-handshake and statistics/lifecycle tests
and found no remaining issue.

The build reviewer found version-prefix substring matching accepting unrelated
native releases. Fourteen boundary cases failed before complete-token matching
and passed afterward. All seven installer tests pass, including both architectures,
both CLIs, delayed metadata/install, terminal failures and watchdogs. Real isolated
x64 installs pass OpenCode 2.0.30 and Codex 0.163.0. Re-review found no remaining issue.

The onboarding reviewer found no actionable issue and verified manual source
hashes, source/export inventories, missing-SDK behavior, licenses, hosting and
preserved corruption controls. Runtime/browser evidence is separate from review.

The initial both-pin clean browser run passes ten rooms and twenty real report
downloads. Every peer-room record requires actual restores and independently
compared corrected canonical state; both altered-load controls fail at frame 3.
A final run includes the reviewed privacy/latch fix and guide changes.
Final receipts, native suite counts and delivery gates are recorded below.

## Remaining scope

#42 retains bounded canonical trace/replay artifacts and application metadata.
#39 retains Firefox/WebKit/mixed-browser and supported-release scale evidence.
#38/#75 retain advanced path restoration/congestion and lifecycle recovery.
The two-peer Chromium loopback witness establishes neither public-network
connectivity nor a supported full browser release.

Retro: findings-acted.

## Final local evidence

The final source-bound clean browser receipt is
`.cache/reference/results/session-022-clean-online-final/online-example.json`.
It binds the final reviewed runtime, installation/hosting/validation helpers,
Python/editor/browser/server tools, both user guides, exports and owned logs.
Both pins pass five rooms, at least 100 confirmed frames per peer, real rollback,
twenty actual downloaded reports and intended frame-3 corruption rejection.
Both absent-SDK projects contain 61 authored files and independently match
frame-24 canonical offline state. The new guide screenshot comes from the final
4.7.2 browser run and shows complete controls and actual rollback statistics.

Reproduce the full clean-install/browser flow:

```sh
python3 scripts/reference/signalfish_webrtc_probe.py --online-example --offline \
  --server .cache/reference/results/session-013-server-build/target/debug/signal-fish-server \
  --server-source .cache/reference/signal-fish-server-9c2fb8fa635a69241b8ccf38be651d561fef7434 \
  --build-receipt .cache/reference/results/session-013-server-build/build-receipt.json \
  --output .cache/reference/results/session-022-clean-online-final
```

All 106 harness/tooling tests and all 79 reference tests pass (three environment
skips in the latter). Source-width and harness lint pass. Native unit/integration/
determinism and ownership receipts are completing under the final reviewed source;
CI supplies independent current-head and architecture evidence before merge.

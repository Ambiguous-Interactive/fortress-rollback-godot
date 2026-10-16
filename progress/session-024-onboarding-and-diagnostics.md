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
Local receipts and native suite counts are recorded below. PR #98 records final delivery gates.

## Remaining scope

#42 retains bounded canonical trace/replay artifacts and application metadata.
#39 retains Firefox/WebKit/mixed-browser and supported-release scale evidence.
#38/#75 retain advanced path restoration/congestion and lifecycle recovery.
The two-peer Chromium loopback witness establishes neither public-network
connectivity nor a supported full browser release.

Retro: findings-acted.

## Local evidence before CI

The pre-CI source-bound clean browser receipt is
`.cache/reference/results/session024-clean-online-final/online-example.json`.
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
  --output .cache/reference/results/session024-clean-online-final
```

All 106 harness/tooling tests and all 79 reference tests pass (three environment
skips in the latter). Source-width and harness lint pass. Both engine pins pass all 224 unit, four integration and eight determinism cases,
with in-process and fresh-process repetition. Receipts:
`.cache/tests/session024-final-{4.3,4.7.2}-{unit,integration,determinism}.json`.
Final formatting passes for changed production GDScript and the new statistics suite;
existing unrelated fixture formatting is preserved. Independent current-head CI and
complete feedback gates remain required before the authorized squash merge.
The linked PR records reviewed head, feedback times, merge SHA and main CI.

The first PR head's full x64/ARM64 container builds passed. Its automatic review
also found no issues. The final formatting pass changes only GDScript whitespace
and Python import placement; source-bound browser receipts were refreshed on both
pins afterward. The final screenshot reflects that exact run. It observes ten
rooms, sixteen rejected stale SDK callback invocations and twenty downloaded
reports, with real rollback in every peer-room record.

The final `python3 scripts/reference/ownership_probes.py --offline --web` also
passes on both engine pins. `.cache/reference/results/ownership.json` contains
four positive/negative native+Chromium records, with exact native/browser equality
and the expanded actual-handshake privacy/ownership assertions. No probe process
remains running. Source-width lint checks all 252 tracked source files at 180
columns; harness lint and the 106 tooling tests pass. The final browser receipt
also binds the actual Python executable used for clean installation.

## CI download-timing incident

Final-head CI run `38835699249`, job `116764215997`, passed the real browser
WebRTC phase but rejected the online peer-departure observation. The uploaded
artifact `12019008558` shows correct terminal state/message and an unchanged
frontier at frame 289. Serial diagnostic downloads ran during active gameplay:
peer observations advanced 175→207 and 217→257 while those downloads completed.
The departure boundary then exceeded the deliberately bounded 256-frame witness.
Three local two-pin runs did not expose the slower CI download path.

The test fixture must collect reports after verified physical teardown, where
the retained match and diagnostic button remain available. Leave detaches the
network; the next connection replaces the match. The repair preserves every
gameplay and terminal frame bound, and requires offline, unchanged frame/restore
observations during downloads. This is a test orchestration defect; no game or
protocol behavior is changed to hide it. Subsequent source-bound browser receipts
and current-head CI must supersede the earlier passing local observations.

The repair's negative control shows the old validator accepting nine live or
advancing download observations. The repaired Python observer rejects those
cases and still requires exactly two real downloads per room. The actual Node
collector is independently exercised with delayed completion, live invocation,
resumed state and changed frame/restore counters; storage methods are restored
on success and failure. All eight Node and 80 reference Python tests pass
(three environment skips in the latter). A fresh adversarial review reports no
actionable finding. Frame-256, terminal freeze, canonical-history and corrupted
load gates are unchanged; no process budget is increased.

## Final repair verification

`.cache/reference/results/session024-download-repair-final/online-example.json`
supersedes the pre-CI local browser receipt. Both pins pass all five rooms, twenty
real downloads and sixteen stale callback invocations. Every download observes
offline state with exactly unchanged frame and restore counts. Departure freezes
at frame 118 on 4.3 and 112 on 4.7.2; the failed CI froze at 289. Corrected canonical
prefixes, original inputs, actual rollback, all frame-256 guards and intended
frame-3 corruption rejection remain required and pass. No runtime source changes
are part of this CI repair. The fresh reviewer independently ran eight Node and
sixteen focused Python tests and found no issue.

Reproduce with the browser command above, selecting
`--output .cache/reference/results/session024-download-repair-final`.
Final-head CI and post-green/pre-merge feedback must pass after this repair.

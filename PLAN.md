# Fortress Rollback Godot — Implementation Plan

## Purpose and source of truth

Build a correctness-first, GDScript-native reimplementation of Fortress Rollback
for browser Godot games using SignalFish.

Priority order is **correctness → simple client interface → measured performance**.
An optimization cannot weaken a correctness gate or obscure the client contract.

This document contains durable decisions and navigation.
**GitHub issues own implementation details, TODOs, dependencies, progress,
experiments, acceptance criteria and closure evidence.**
Do not maintain a second changing task checklist in this file.
Read and update GitHub through authenticated MCP first, then authenticated `gh`
for capability gaps; follow [GitHub operations](.llm/skills/github-operations/SKILL.md).

- Roadmap: [GDScript-native Fortress Rollback implementation and parity tracking](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/2).
- Start here: [pin and reproduce the reference baseline](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/12).
- The roadmap and parent/child issue links own the changing backlog.
- Parent/child linked checklists provide the epic hierarchy.
- Individual task prerequisites determine readiness; issue-number order does not.
- Close parents only after their applicable child tasks and gates are satisfied.

Local development contracts and evidence entry points:

- [Pinned reference setup, run instructions and evidence](docs/reference/README.md).
  Source and tool pins were refreshed on 2026-10-28; historical receipts retain their original revisions.
- [Session/driver/state/transport interface ADR](docs/contracts.md).
- [Verification and release evidence policy](docs/verification-policy.md).
- [Fail-closed native test runner](docs/test-runner.md).
- [Game integration guide, frame loop and confirmed one-time effects](docs/integration.md).
- [Match recording, replay files, verified captured prefixes and playback failure evidence](docs/integration.md#record-and-replay-a-match).
- [Confirmed-input spectator playback, bounded envelopes, retained publication, viewed-history replay export and local buffering/pause/restart guidance](docs/spectators.md).
- [Online match recording, downloads and online/spectator offline replay viewer with backward/input inspection and comparison-specific failure reports](docs/online-example.md#record-and-download-a-replay).
- [Addon candidate packaging and clean installation](docs/package.md).
- [Supported features, browsers, platforms and explicit exclusions](docs/supported.md).
- [Native/browser diagnostic file viewer, including saved callback failure names and frames](docs/diagnostic-viewer.md).
- [Offline canonical diagnostic reproduction](docs/diagnostic-reproduction.md).
- [Runtime input-delay increases and their result codes](docs/integration.md#change-input-delay-during-a-match).
- [Measured input-delay suggestions](docs/integration.md#suggested-input-delay).
- [Playable input-driven shots, confirmation and prediction stalls](docs/integration.md#try-the-effects-example).
- [Playable online room setup and controls](docs/online-example.md).
- [Online suspension, elapsed-time expiry and fresh-room restart](docs/online-example.md#suspension-and-expiry).
- [Online terminal connection cleanup and fresh-room recovery](docs/online-example.md#leave-and-restart).
- [Actual server-process restart and old-room packet rejection](docs/online-example.md#verification).
- [Source-family inventory and remaining semantic audit](docs/reference/INVENTORY.md).
- [Measured packed-buffer and snapshot ownership](docs/experiments/buffer-ownership.md).
- [Firefox late updater-lock regression and full shutdown](docs/experiments/firefox-shutdown.md).
- [Measured integer and fixed-width encoding contracts](docs/experiments/integer-encoding.md).
- [Measured session hot path, snapshot copy and codec cost](docs/experiments/session-hot-path-performance.md).
- [Measured Reference Baseline job time and the dominant browser work](docs/reference/jobs.md).
- [Audited raw input queue and prediction contracts](docs/input-queue.md).
- [Actual upstream and production Godot sync-test differential traces](docs/oracle.md).
- [Shared session engine, bounded snapshots and game driver](docs/session.md).
- [Opt-in bounded canonical first-divergence evidence](docs/peer-lifecycle.md#opt-in-canonical-divergence-evidence).
- [Bounded protocol message layout and source audit](docs/protocol.md).
- [Fixed-peer byte handshake and injected time/token API](docs/handshake.md).
- [Actual upstream/Godot handshake observations and scoped model refinement](docs/oracle-handshake.md).
- [Fixed-membership byte sessions and transport-facing API](docs/peer-session.md).
- [Peer timing, confirmed game checksums and terminal events](docs/peer-lifecycle.md).
- [Owned rollback statistics and private diagnostic downloads](docs/peer-lifecycle.md#downloadable-observations).
- [Opt-in online canonical state/input downloads](docs/online-example.md#diagnostics).
- [Optional SignalFish membership, agreed UUID slots and plan fences](docs/signalfish-membership.md).
- [SignalFish binary relay, bounded packet ownership and broadcast filtering](docs/signalfish-relay.md).
- [SignalFish WebRTC bytes, channel selection and direct-path lifetime](docs/signalfish-webrtc.md).
- [SignalFish per-peer fallback, direct restoration and mixed-path ownership](docs/signalfish-fallback.md).
- [Bounded retained input, cumulative ACK and gossip exchange](docs/input-exchange.md).
- [Actual upstream/Godot P2P fault traces](docs/oracle-p2p.md).
- [Playable two-peer packet fault example](docs/peer-example.md).
- [Runnable offline driver and presentation example](docs/offline-example.md).
- `make test-reference` runs offline tooling negative controls;
  `make reference-baseline` reproduces the Rust reference, not the Godot port.

The planning deliverable is this file and its linked issues.
Issue creation does not establish implementation, test success or feature parity.

## Agreed product decisions

| Decision | Contract |
| --- | --- |
| Runtime | Pure GDScript; no Rust, C#, GDExtension or compiled addon dependency |
| Engine floor | Godot 4.3; test the minimum and current stable release |
| First supported browser tier | 2–8 players; test every count in deterministic simulation |
| Real-browser scale points | 2, 4 and 8 peers, including mixed browsers |
| Browser transports | WebRTC plus SignalFish binary relay and fallback |
| Compatibility | Behavioral parity for supported features against a pinned upstream |
| Wire compatibility | Rust/Godot mixed sessions are outside the committed scope |
| Default API | Small save/load/simulate driver plus explicit expert request API |
| Feature delivery | Fixed-membership P2P first, then staged advanced parity |
| Verification | Rust oracle, independent invariants, properties and bounded formal checks |
| Development tools | Rust and formal tools permitted; excluded from shipped addon |
| Upstream notifications | Weekly/manual workflow updating a deduplicated GitHub issue |
| Scene integration | Explicit state capture; automatic node replication is outside scope |

The game owns deterministic simulation and complete serialization.
The library supplies orchestration, validation and sync-test tooling.
Request-scoped inputs support owned reads or checked copies into exact-width game scratch buffers.
The scalar applied-status read preserves predicted and disconnected semantics alongside reusable input buffers.
Queue history uses native byte copying with shared immutable private storage; submitted and returned buffers remain isolated.
Rejected driver sample lists preserve the accepted poll time so corrected retries remain usable.
Peer clients can read owned staged local samples to retry stalled steps without resampling.
Callback and expert peer steps can omit retained local slots while requiring every unstaged slot before mutation.
Internal readiness checks avoid owned sample copies; public retained-input reads remain isolated.
They can also export owned finalized input rows for confirmed effects and spectator publication without recording.
Replay failure evidence identifies the first failed game request and comparison domain.
The online replay viewer can inspect preceding or following control/status changes through bounded verified navigation.
It also discovers preceding/following recorded checksum boundaries, including final states, independently of visited checkpoint caches.
Spectator playback observations distinguish contiguous input waits, deliberate delay, final tails and committed termination.
The local spectator example adjusts its viewing delay without rewinding playback or changing its pause and catch-up policy.
Integration controllers validate ownership, retained input and time before staging input or advancing clocks, and pause live service while replay is open.
Online room and match service also preserve callback, notification and manual ownership before committing clocks or replay finishing.
Standalone driver parity covers independently raised local-slot delays with retained samples through rollback and queue reuse.
Replay viewer controls preserve active callback/manual-request ownership and retire replaced players.
Replay inspection distinguishes recorded checksum validation at the displayed state from lifetime coverage and cached-state comparisons.
Explicit finalized-boundary capture adds FRRP v6 terminal checksums; ordinary v4/v5 playback retains its historical coverage.
Owned replay prefixes only trim existing storage; they cannot pad missing gameplay or checksum bytes into portable evidence.
Validated terminal states share the bounded checkpoint cache, allowing direct return to a verified ending after backward inspection.
Spectator startup traces compare actual pinned Rust and Godot execution against a scoped runtime-aligned model relation.
A separate source comparison checks each initially disconnected reserved-slot position across all supported rosters, delay and ring reuse.
Remote recording compares symmetric and asymmetric late corrections, repeated prediction stalls and resumed retained samples
through default queue reuse with independent canonical histories;
[pinned speculative-checksum discrepancies](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/253) remain explicit.
Authenticated spectator byte streams ignore validated duplicates after viewed history expires without renewing host liveness.
The same policy applies to custom transports and the SignalFish adapter.
The [queue append benchmark](docs/experiments/input-queue-performance.md) records the measured scope and narrow-input noise.
Godot physics and arbitrary scene state are not made deterministic by rollback.

## Reference revisions and provenance

Research inspected these exact revisions:

| Project | Research baseline |
| --- | --- |
| Fortress Rollback | `d124c89080004d96971a629bb0427056ee1805e3` |
| SignalFish Godot SDK | `8e1475ed12a618fb41660bd1c8a1b0c934dee77f` |
| SignalFish server | `8cbf5d9e5dc155e7a7a4f8f5593f0a24f8aaa560` |

These are inputs to baseline reproduction, not claims that all upstream suites
were executed during planning. B1 records actual results and intentional updates.
Pin toolchains, feature flags, lockfiles, engine/export-template pairs,
browser runners, models and artifact integrity alongside source revisions.

Keep upstream references in a development cache and preserve attribution.
Every imported fixture records its source revision and translation, if any.
A test inventory must come from the pinned tree, not historical README counts.

## Epic map and milestone gates

| Epic | Work and acceptance gate |
| --- | --- |
| [E1 — Baseline and contracts](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/3) | Reproduce pins; inventory applicability; settle interfaces and evidence rules |
| [E2 — Verification infrastructure](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/4) | Real differential traces, independent oracle, shrinking and scoped model checks |
| [E3 — Representation experiments](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/5) | Measured integer, ownership, encoding and allocation contracts |
| [E4 — Rollback core](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/6) | Exact core behavior, bounded history and working sync-test sessions |
| [E5 — P2P protocol](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/7) | Confirmed agreement and bounded recovery across 2–8-peer fault scenarios |
| [E6 — SignalFish and browsers](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/8) | Real direct, relay and mixed-path sessions with safe lifecycle behavior |
| [E7 — Client API and release](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/9) | Usable driver/examples, measured performance and supported-release evidence |
| [E8 — Advanced parity](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/10) | Independently gated replay, spectators, delay, peer drop and hot join |
| [E9 — Maintenance](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/11) | Conservative drift classification, weekly reporting and reviewed upgrades |

E1 establishes the contracts. E2 and E3 can overlap after their prerequisites.
E4 builds on verified representations and comparison tooling; E5 adds networking.
E6 validates the browser target while E7's driver work proceeds against the core.
E7's release gate requires both protocol and real-browser evidence.
E8 features ship only after their individual gates.
E9 starts once baseline and differential infrastructure exist; it need not wait
for advanced parity. Epic dependencies are milestone gates, not blanket locks.

## Task navigation

The issue bodies specify requirements, dependencies, tests and closure evidence.
This index is navigation rather than a duplicate progress tracker.

| Area | Task issues |
| --- | --- |
| Baseline | [B1 pins](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/12); [B2 inventory](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/13); [B3 interfaces](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/14); [B4 evidence policy](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/15) |
| Verification | [V1 runner](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/16); [V2 Rust oracle](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/17); [V3 comparator](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/18); [V4 network/shrinker](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/19); [V5 formal/properties](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/20); [V6 CI tiers](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/21) |
| Experiments | [R1 integers/encoding](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/22); [R2 ownership](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/23); [R3 benchmarks](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/24) |
| Core | [C1 queues/delay](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/25); [C2 prediction](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/26); [C3 rollback/history](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/27); [C4 sync-test](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/28); [C5 expert API](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/29) |
| Protocol | [P1 codec](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/30); [P2 handshake](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/31); [P3 input/ACKs](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/32); [P4 pacing/desync/drop](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/33); [P5 mesh validation](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/34) |
| SignalFish | [S1 SDK/identity](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/35); [S2 relay](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/36); [S3 WebRTC](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/37); [S4 fallback/lifecycle](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/38); [S5 browsers](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/39) |
| Client/release | [A1 driver](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/40); [A2 examples/docs](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/41); [A3 diagnostics](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/42); [A4 optimization](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/43); [A5 release](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/44) |
| Advanced parity | [X1 replay](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/45); [X2 runtime delay](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/46); [X3 spectators](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/47); [X4 coordinated drop](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/48); [X5 redundant hosts](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/49); [X6 hot join](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/50) |
| Maintenance | [M1 classification](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/51); [M2 reporting](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/52); [M3 reviewed upgrades](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/53) |

## Architecture

The runtime core includes the bounded raw queue, frame/generation-tagged snapshots,
shared ordered request engine, local sync-test mode and synchronous game driver.
`make oracle-probes` compares production Godot sync-test requests and canonical
bytes, including snapshotted PRNG and pending-event games, directly with pinned upstream sessions. External-input tests verify
asymmetric prediction and corrected replay. `make p2p-probes` compares actual
upstream and Godot byte sessions across 2–8 slots, delayed inputs, packet faults
and scoped timing, checksum and terminal observations.
[#59](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/59)
retains long-lived partition/fairness vocabulary and first-divergence shrinking.
These scoped gates do not establish browser or full-feature release parity.

| Layer | Responsibility |
| --- | --- |
| Deterministic core | Input queues, prediction, confirmation, saved-state history, rollback |
| Session/protocol | Handshake, input exchange, ACKs, retries, pacing, lifecycle, checksums |
| Transport adapters | Bounded fake network, SignalFish relay and WebRTC byte delivery |
| Client driver | Ordered state callbacks, status handling and end-of-step notifications |

Core classes are typed and SceneTree-independent; no hidden global state.
Simulation advances in whole frames with stable player order and integer-first
reference games. No network I/O, wall-clock reads or presentation work occurs
inside simulation callbacks.

Protocol time is separately injected and monotonic.
Production may use a local monotonic clock; deterministic tests advance it
explicitly. Protocol request identities have a controllable test source.
Browser suspension advances elapsed protocol time truthfully on resume.

Match audited upstream defaults where supported; examples run at 60 Hz.
Validate configuration once and derive bounded storage from explicit limits.
Keep engine-version-specific syntax out of the Godot 4.3-compatible core.

## Public interface and ownership

| Interface | Required behavior |
| --- | --- |
| `FortressConfig` | Validated input width, player setup, prediction/history and memory limits |
| `FortressSession` | Poll, submit local input, advance, consume requests/events, inspect status |
| `FortressGame` | Save to bounded writer, restore from snapshot reader, simulate frame inputs |
| `FortressDriver` | Fulfill ordered requests synchronously through the same session engine; report the session state, counters and terminal cause |
| `FortressTransport` | Bounded nonblocking send/receive with identity and backpressure |

Driver and expert API must never implement separate rollback algorithms.
Compare their ordered callbacks, notifications and canonical history through
partial publication, retained-input retries and runtime input-delay changes.
Represent save/load/advance requests and player input statuses explicitly.
Use typed statuses to distinguish prediction stalls/not-ready from fatal errors.
Document frame conventions and request completion before implementing storage.

Submitted input bytes are copied into owned history.
Snapshot slots own their storage and carry frame/generation tags.
Callback views are valid only for their documented operation.
Reject oversized snapshots, stale slots and incomplete request consumption.
Refuse recursive advancement and stop explicitly on callback failure.

Emit notifications after request processing; signals do not control mid-tick
simulation. Presentation reads the final state after resimulation.
Examples must prevent duplicate sound/effects using confirmed events or stable
event identities; presentation state is not a substitute for complete snapshots.

## Behavioral parity and evidence limits

The parity ledger maps upstream behavior/test identity to source revision/hash,
applicability, target task, port tests and coverage status.
Allowed statuses distinguish pending, covered, deferred, not applicable and
intentional divergence. Exclusions need a concrete rationale.

Inventory includes inline tests, integration/property tests, fuzz targets,
regression corpora, wire goldens, feature flags, examples/doctests, models and
allocation contracts. Language-specific mechanisms can be inapplicable while
their behavioral obligations remain relevant.

The Rust oracle runs actual upstream code through public interfaces and existing
verification hooks. It does not translate algorithms into a second homemade
reference. Add minimal observation hooks only when justified and reviewed.

Shared versioned scenarios specify configuration, byte inputs, API operations,
explicit time and delivery decisions. Traces record ordered requests,
input statuses, events/errors, confirmation and canonical state bytes.
Encode wide integers/checksums losslessly across JSON tooling.

Core comparisons are exact. Protocol comparisons use an explicit semantic
projection because wire encodings may differ.
Normalize representation and random token names only while preserving identity
equality, event order, duplicate relationships and acknowledgement content.
Unknown records, partial consumption, crashes and timeouts fail the gate.

An independent offline reference game computes expected confirmed states from
actual input histories. Compare peers at globally confirmed frames, before
history eviction; speculative states may legitimately differ.
Compare canonical bytes in tests, not just checksums.

If upstream disagrees with an independent invariant, minimize and investigate.
Record a reviewed divergence or upstream defect; never silently bless it.
Golden regeneration is a reviewed change, not an automatic repair.

## Formal, property and fault verification

Reuse upstream TLA+ models beginning with handshake, input queue and rollback.
Map observed runtime transitions to model actions/variables and document gaps.
Require full trace consumption, non-vacuity witnesses and targeted mutations.
Tool failure or timeout is not evidence of a rejected invalid transition.

Bounded exhaustive checks cover small queues/windows and state-machine domains.
Property tests cover run-twice identity, save/restore continuation,
serialization identity and rollback-resimulation equivalence.
Apply metamorphic relations only where their preconditions hold.

The deterministic scheduler covers delay, jitter, loss, duplication, reordering,
asymmetric partitions, healing, bandwidth and backpressure.
Use stable scheduling and explicit seeds across every player count 2–8.
State fairness and bounded recovery assumptions when testing liveness.

Shrink failing traces while retaining scenario validity and the failure class.
Keep minimized failures as permanent regression cases with provenance.
Rust-specific Kani/SMT/Loom evidence does not automatically prove GDScript code.
No finite test corpus or bounded model establishes whole-program equivalence.

## SignalFish integration and browser behavior

Reuse the existing SDK through an optional adapter.
The core addon must parse and run without SignalFish installed.
An exhausted prediction window must retain a bounded receipt-gossip carrier
after ordinary input ACKs drain. Recovery preserves the same samples and
conservative remote confirmation evidence; ordinary input-idle polling retains its existing compatibility behavior.
Explicit peer recovery keeps bounded receipt gossip alive even below prediction-window
exhaustion, so a final prefix can confirm without another sample when delivery continues.
The [membership seam](docs/signalfish-membership.md) derives frozen UUID slots
and binds the full roster/configuration into the existing peer handshake.
Its plan route describes validated setup; byte delivery remains a separate adapter contract.
Use SDK public interfaces for binary data, plans, signaling and mesh setup.

Agree a stable UUID-to-player-slot roster and configuration at session start.
Detect peer-ID collisions and validate transport-attributed senders.
Keep rollback session identity, SignalFish incarnation and plan generation
distinct; never renumber active players because roster order changed.

Relay is a broadcast-capable path, so envelopes identify intended recipients.
Validate negotiated binary mode and actual byte pass-through behavior.
Binary relay is reliable and can introduce head-of-line delay.
Bound application queues and receive work; expose backpressure rather than
building unlimited latency. Preserve recoverability of unacknowledged inputs.

Use unreliable unordered WebRTC input delivery with protocol redundancy.
Inspect actual SDK/Godot channel options; do not claim zero retransmits if the
mesh uses packet lifetime instead. Reserve packet consumption for the adapter.
Respect server-selected offerer roles and latest plan generations.
The direct adapter now provides bounded byte delivery and lifetime fences.
The exported Chromium witness covers 2/4/8 peers on both pinned engines.
The slow eight-peer FIFO regression requires actual receipt and confirmation;
live witness send/receive work budgets must match its tested configuration.
The witness exercises elapsed transport deadlines and caller-owned handshake
retries; [#72](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/72)
records its loss regression and delivery gate.
The bounded fallback coordinator routes individual unready links through relay
and restores ready direct channels in the same rollback session. Injected
three-peer tests cover overlapping delivery and corrected canonical game history.
Terminal direct SDK errors fence composed relay publication; ordinary send pressure remains recoverable.
Transport polls report the traffic they moved, refused packets included, so a
bounded service batch can stop on an idle route without leaving valid bytes
queued behind refused traffic.
Exported Chromium also exercises actual mixed-path packets under injected
single-link send pressure, using default and selected work budgets on both pins.
It correlates one input packet across direct and relay receipt, requires restored
direct sends, and rejects a fallback-disabled stall. A physical-outage room also closes one actual unreliable channel at frame four.
The affected pair continues on relay through confirmed original game history,
while healthy links stay direct. Idempotent engine peer removal prevents duplicate
SDK teardown errors. ICE restoration, relay congestion, replan handling and the
full browser matrix remain acceptance work in S3–S5 and #75; keep those tasks open.

Direct and relay paths use the same session identity and deduplication rules.
Test overlapping delivery, asymmetric failure and mixed paths.
A transport switch does not reset confirmation or simulation history.
SignalFish authority/reconnection is not rollback authority/state recovery.

On resume, bound catch-up and enforce timeout/history limits.
Before advanced reactivation is supported, unrecoverable sessions require
explicit termination/restart. Server-process death requires terminal cleanup and an explicit fresh-room restart.
The exported online witness verifies that flow on both pinned engines, including
old-room input delivered over new channels; server restart is not a transparent resume.
Native WebRTC availability is verified independently of browser support.

## Test tiers and release acceptance

| Tier | Required evidence |
| --- | --- |
| PR | Unit/core tests, fixed differential corpus, short faults, minimum/current Godot |
| Nightly | Larger seeded exploration, shrinking, mutations, models, browser integration |
| Release | Native state-byte equality, real browser matrix, sustained bounded-memory runs |

Native release comparisons cover Linux, macOS and Windows.
Real browsers cover Chromium, Firefox and WebKit, including mixed peers.
Report WebKit automation separately from actual Safari/device evidence.
Run actual exported simulations over a pinned local SignalFish server;
page load and connected-state smoke checks do not establish rollback coverage.

Acceptance includes frame zero/sentinels, integer limits, ring wrap,
prediction-window edges, earliest misprediction, snapshot aliasing and failures,
invalid configuration, truncated packets, duplicate/stale ACKs,
queue exhaustion, partitions, desync detection, re-plans and suspension.
Mutations must demonstrate that the runner, comparator and models detect faults.

All advertised features require mapped tests and no unexplained divergence.
Publish engine/template/browser versions, network profiles and known exclusions.
Package only the addon and required notices; verify clean installs without Rust.
Release publication is separate from constructing the reviewable candidate.

## Performance contract

Measure before optimizing; correctness gates remain mandatory afterward.
Benchmark steady frames, maximum rollback, snapshots, serialization and polling.
Vary players, input widths, snapshot sizes and supported prediction windows.
Separate library, client simulation and transport cost.

Record workload, warmup, CPU, OS, engine/browser versions and repeated samples.
Report p50/p95/p99, memory high-water, buffer growth, bandwidth and stalls.
Establish regression budgets from measured noise and reference hardware.
Portable CI must not fail on arbitrary unstable timing thresholds.

Prefer preallocated rings, reusable batches/scratch buffers and dense indexing.
Prove snapshot isolation before removing copies.
Initial guarantee: bounded storage and no intentional steady-state growth.
Claim zero allocations only for measured paths using instrumentation with a
known-allocation positive control; flat memory alone is insufficient.

## Advanced parity boundaries

Driver and peer step/recovery results expose the first failed callback kind alongside terminal reason and frame.
Driver-only clients can export owned opt-in canonical traces, including after callback failure, without retaining the expert session.
Snapshot callbacks can read small fields into reusable buffers without a result wrapper; native byte reads remain preferable for wide snapshots.
Local example restarts retire retained old host/viewer sessions and refuse replacement during active ordered work.
Fixed-membership peers expose callback-free ordered request batches for advancement, recovery and final replay capture.
Callback and manual peers share input publication and completion controls; pending batches fence transport mutation and expire on explicit cancellation.
Encoded P2P acceptance compares both public interfaces under delayed,
lost and duplicated traffic, including multiple local slots and queue reuse. Independent original
input history remains the state oracle; this local comparison does not qualify browser transport.
Coordinated-departure acceptance also compares callback and expert traffic, retained certification,
frozen statuses, predicted-suffix repair and every corrected canonical prefix through continuing gameplay.
Peer callback and completion guards protect the shared engine across facades; terminal handler cancellation preserves its first cause and closes peer links.

Replay viewers report recorded and actually checked checksum coverage separately; checksum-free playback cannot establish validated history.
Replay configuration validates mutable recording structure before ownership. Portable export rejects malformed
metadata/storage and incomplete input digests while preserving stored comparison evidence. Invalid replacements preserve existing playback and validation coverage;
Optional replay compatibility checks accept FortressConfig instances/subclasses and refuse foreign objects before accessing their properties.
Safe missing-digest and content comparisons remain at their owning playback boundary. Missing or incomplete
recorded digests preserve their distinct first-cause label and computed row evidence through callback and expert playback.
Pinned replay comparison covers every supported player count from two through eight, sparse checksums
and an interior mismatch after unchecked frames through both playback interfaces and supported portable versions 4, 5 and 6. The pinned upstream
replay stores inputs without player statuses, so disconnected-status recording remains a Godot extension.
Actual all-local source recording/export now runs every roster size two through eight with
input delays zero/two and prediction windows zero/two. Each runtime round-trips and plays its own format;
source export timing and checksum differences remain explicit in the [recording comparison](docs/oracle-replay.md#actual-recording-applicability).
Continuing extraction compares original gameplay after a mid-match export and retained early playback.
Pinned Rust disables recording after `take_replay()`; Godot keeps recording and returns independent owned exports.
Pausing or stepping a replay validates the displayed boundary and its selected input digest before allowing further playback.
Expert replay clients can validate that same paused boundary through a save-only request batch without consuming input.
Expert checkpoint navigation now shares callback restoration through ordered load/save requests, with exact snapshot validation before committing the selected frame.
Viewer checkpoint controls use the owned inventory of retained validated boundaries and cannot bypass playback failure.
Keyboard playback and frame inspection share the visible controls and preserve frame-entry focus.
Repeated playback compares canonical bytes and checksums against retained boundaries even without recorded state checksums.
Replay checkpoint acceleration is bounded and optional; repeated navigation reuses validated
in-memory snapshots without changing the portable file format. Viewer completion distinguishes a verified final state from historical files without terminal checksums.
Viewer speed controls change
only the bounded number of recorded frames serviced; each simulation step stays fixed.
Callback and expert replay playback share ordered save/advance requests in the same player.
Expert integrations dispatch and acknowledge bounded views themselves; callback navigation remains optional.
Actual-source recording comparisons cover all-local prediction windows zero and two,
retaining empty source service attempts separately from completed simulation frames.
Replay records confirmed gameplay history; diagnostic network traces are a
separate format. Both need versions, validation and reproducible provenance.
Version 5 replay rows preserve confirmed/disconnected player status alongside input bytes; version 4 reads with all-confirmed defaults.
Historical v4/v5 files checksum pre-input boundaries only. Explicit driver and peer capture
add a final-state checksum in v6 after the recorded prefix is finalized and repaired.
The online Finish replay action stops local sampling while confirmation settles; an unavailable
capture preserves historical coverage. Full replay acceptance remains in [#45](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/45).
Native and exported Chromium compare every corrected dropped-player replay boundary through callback and expert playback on both engine pins.
Receipt-only recording rows remain private until mesh confirmation, and coordinated drop repairs that staged tail before export.
Every recorded frame carries a digest of its own input row and, in version 5, its player statuses, because the state
checksum of the following frame only covers a row when that following frame
carries a checksum. Those digests are a Godot-side integrity extension; the pinned
upstream session owns the input history.
Public recording reads refuse incomplete or invalid input/status rows without hiding complete earlier rows; missing metadata and digest bytes remain unavailable.
A recording carries the roster, sample width, neutral input, seed and game version
of the session that produced it, and a player refuses a recording that does not
match the running game. A recording with substituted inputs is reported as such
instead of being presented as a faithful copy.
Validated replay playback and paused navigation check callback success and bounded snapshot status before
accepting a boundary; a matching checksum cannot override a failed snapshot write.
Replay completion also waits for open navigation, revalidation requests and game callbacks to finish.
Confirmation reads current receipt-frame scalars without duplicating endpoint diagnostic history; public status snapshots stay owned.
The ownership witness compares the complete driver, replay and spectator case inventory against native execution in pinned Chromium and Firefox on both engines.
Firefox requires a visible Xvfb window and both declared control phases on each pin; one partition cannot establish qualification.
This API evidence does not establish live transport or full browser-release acceptance.
Runtime input-delay changes must preserve exact upstream scheduling behavior.

Single-host spectators precede redundant-host failover.
The bounded confirmed-input spectator API shares the player request engine and
supports delayed playback, caller-bounded catch-up and explicit host endings. Spectator
confirmation comes from complete host rows; player-mesh confirmation controls are unavailable.
Its local example streams corrected original inputs while the host continues.
Versioned lifetime-bound row envelopes support bounded byte delivery and explicit host expiry.
Every envelope packet carries a keyed tag over its header and body and the digest of the
agreed match, so a viewer accepts only a host that holds the shared key and only a match
it agreed. Network startup can bind the complete canonical original snapshot with the state-bound digest helper;
the caller still owns state agreement, transfer and restoration. The envelope version is 3, and the version and the optional kinds
are negotiated inside that authenticated boundary before the first row, so a peer that
speaks another envelope fails at startup with one recorded reason.
A viewer never simulates a host row it no longer retains, and a reconfigured viewer keeps
the caller's playback policy when it still fits the new ring.
Successful stream replacement retires the prior owned playback lifetime, including retained drivers.
The small driver exposes owned finalized inputs and replay exports through the expert session's gates.
Driver-only clients can cancel through the same terminal lifecycle, including inside callbacks; cancellation expires active views.
Completion notifications guard the shared session, so another driver or expert facade cannot advance or reconfigure it between handlers.
Remote-input sessions can recover and finalize confirmed replay history without another local sample
or forward frame. The local spectator example exposes bounded catch-up rate controls independently of viewing delay.
Its identified saved recordings open in the shared replay viewer with their own game callbacks and control labels.
The actual 36,000-frame spectator export round-trips through bounded seeking and complete playback against independently simulated original inputs.
The spectator example uses that shared operation to settle its exact final host
boundary before sending END; paused viewers can resume through the full clean tail.
Authenticated retries remain idempotent through that buffered tail; input closure alone does not terminate playback.
Direct clean closure refuses accepted rows beyond a gap without closing input; callers fill the missing rows and retry before draining the complete tail.
After playback reaches the authenticated END boundary, relay polling preserves normal completion and discards late ingress; unfinished cancellation and failures stay distinct.
The host publisher retains one exact refused packet, advances only on transport acceptance,
and fences host replacement while keeping liveness separate from row pressure.
Stream delivery and expiry remain bound to the configured playback lifetime; direct viewer replacement requires fresh stream setup.
Bounded typed spectator playback events distinguish contiguous host receipt, clean input closure and actual playback termination.
Owned playback observations distinguish contiguous playable input from retained rows beyond a gap; the example names the first missing frame and shows both buffer counts while paused.
These local events do not establish host authentication or a network handshake.
`is_complete()` identifies serviced clean playback completion; cancellation and failures preserve their first cause without claiming completion.
The spectator relay uses that completion authority even when cancellation occurs exactly at an authenticated final boundary or inside acceptance delivery.
Actual pinned Rust and Godot spectator traces compare startup prefill, capacities two/three,
catch-up speeds one/two and exact input transcripts through ring reuse. The scoped startup relation in
[#203](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/203) is complete.
An anchored runtime-aligned model checks every observed state while preserving the original pinned
startup counterexample and explicit synthetic synchronization setup. Separate actual-source traces compare
delay one and capacity-minus-one through ring reuse, including exact catch-up service cycles.
The source comparison also exercises every roster size two through eight with changing input in
every slot, complete ordered ring observations and a player-order mutation that preserves row sums.
Broader delay and tail policies, event/status,
arbitrary-delivery and live acceptance remain in #47 and #131.
Spectator rows preserve finalized confirmed/disconnected status through publication, authenticated
version 3 delivery, playback requests and confirmed exports. Byte-only callers default to
all-confirmed; dropped matches must supply statuses. Frozen versions 1 and 2 are refused at startup.
Scripted SDK adapter tests preserve corrected status-sensitive history through refused publication,
source-ring eviction, delayed catch-up and clean completion; this does not qualify live drop delivery.
Spectator playback rejects player-freeze operations; complete host rows remain the sole input authority.
Authenticated startup offers share row delivery’s deadline, callback and terminal-lifetime fences.
The receive-only SignalFish spectator adapter bounds authenticated host ingress, SDK lifetimes and elapsed expiry without seating viewers.
Selected-host departure or reconnection stops buffered viewing immediately; admitted-viewer departure stops publication without changing seated gameplay.
Unrelated participant roster events preserve ongoing streams, and setup callbacks use the same participant lifetime fences.
The host SDK bridge publishes one pre-admitted viewer from frame zero with bounded exact-byte retries; separate authenticated acceptance remains caller-owned.
SDK getters cannot publish through a host request they open synchronously; the exact packet remains retryable after request completion.
Spectator relay retains authenticated startup acceptance for a caller-supplied control sender, independently of row pressure.
Its bounded receive scan admits earlier gap rows behind refused future rows while retaining exact packet ownership.
Runtime SDK receive limits must still fit the agreed spectator packets; shrinking them retires queued playback before delivery.
Caller-owned startup acceptance refuses terminated or actively serviced viewers; an idle retry preserves the agreed bytes.
Keepalive priority yields to queued row work so repeated host heartbeats cannot starve confirmed playback under a one-packet receive budget.
Transport acceptance does not establish host receipt. Production application admission and broader
upstream spectator differential/model acceptance remain open in #131 and #47. The reviewed SDK/server
pins include the current upstream work; native relay and exported Chromium WebRTC qualify the upgraded integration.
The [spectator qualification evidence](docs/reference/spectator-relay-qualification.md) records the qualified scope.
The native Fortress witness requires actual SDK/server publication and viewer receipt,
original canonical agreement and a bounded authenticated loopback admission/acceptance path.
Native physical host/viewer socket departures stop paused buffered viewing; viewer loss
also preserves the seated host's canonical continuation.
The exported Chromium viewer now runs in an independent browser context on both engine pins,
receives original state/configuration through a role-separated cross-origin authenticated control boundary,
and consumes real relay OFFER/rows/END while comparing 48 independent canonical boundaries.
Pause/catch-up, clean completion and altered initial-state rejection are qualified for this viewer/native-host slice.
Physical exported-viewer departure also stops paused buffered playback while the native host preserves canonical seated gameplay.
Physical selected-host departure stops the exported viewer before adapter polling can consume buffered rows;
its own socket remains connected, and an independent seated SDK client confirms the exact host departure.
The development bearer service is not a production identity provider; seated remote inputs remain an injected schedule.
[Exported spectator qualification](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/245)
retains exported host/seated transport, replacement, pressure and remaining browser lifecycle cells.
Coordinated peer drop must preserve exposed confirmed history and irreversible
commit semantics; a local minimum-received-frame shortcut is insufficient.
The opt-in graceful drop freezes a departed slot at the mesh-confirmed frame so
the survivors keep playing and reports a disconnected input status. The
survivors now agree that frame first: the survivor that owns the lowest
surviving slot proposes the cut, every other survivor answers with the frame
window it can still freeze, and the proposer commits the frame all of them can
retain, so the survivors keep one confirmed history. The survivors also certify
the value they freeze on: every survivor answers with the frame through which
it retains the departed slot's inputs, the proposer sends the frozen value to
the survivors that already released it in bounded chunks, and every survivor
certifies the frame and the digest of that value before the irreversible commit.
A matching repeated commit is acknowledged after the slot freezes, and the
proposer stops retries after every live survivor acknowledges. Every phase is
fenced by the complete locally derived operation identity and sender role.
Committed retries remain eligible after the pending agreement's negotiation deadline;
acknowledgement, survivor departure or local termination ends their eligible work.
Refused control sends remain immediately retryable after output drains; accepted survivor links keep their own retry intervals under partial pressure, including READY certificates.
Historical donor plans apply the same per-survivor acceptance clocks, leaving healthy output capacity available for retained history chunks.
Bounded donor chunk service rotates across survivors so refused links cannot starve later healthy links.
Remote donors also yield accepted certificate turns to history retries while another certificate destination refuses.
A survivor lost before commit aborts the local attempt with `participant_lost`
and ends the match; committed decisions remain irreversible. A certificate
that names another value ends the match with a recorded reason
instead of freezing divergent values. The match holds while the barrier runs
and a barrier that cannot agree ends the match with a recorded reason.
A freeze refuses a cut below the protected confirmed frontier before changing history. Three real peer sessions now run that barrier end to end:
one peer stops answering, the two survivors agree one frame, keep one
confirmed history and keep playing, and a second departure leaves one
survivor that preserves every retained original target input before freezing its slots at the receipt-raised cut. The reviewed prepare,
backfill, certificate and commit barrier is ported: the Godot tier agrees the
frame and the pinned tier certifies the frozen value. The retained-history tier negotiates its feature before gameplay, raises the cut to
cover exposed frontiers and target receipts, and certifies complete retained actual
intervals. Followers independently compare supplied frozen values with their retained cut inputs before certification.
Bounded donor journals repair missing actual ranges before certification,
including when the donor differs from the coordinator. [#188](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/188)
retains expanded source and live missing-history acceptance. A scoped
[actual-source comparison](docs/oracle-p2p.md#scoped-coordinated-drop-history-comparison)
now checks clean and lost-first-history remote-donor recovery against independent original canonical prefixes and finalized statuses.
Grouped four-row cases also create unequal public exposed frontiers four/five through a real coordinator advance; complete source inventories and negative controls bind that evidence.
The unequal grouped schedule also loses the first irreversible COMMIT, alone and after donor-history loss, and requires its exact retry before continued original-history agreement.
The same scope loses the first follower inventory answer, alone and with history/COMMIT/ACK loss, requiring its exact received retry before irreversible commit.
Follower-acknowledgement loss additionally requires exact certificate redelivery. Godot observes the repeated COMMIT
before the matching ACK response; the pinned source retains its independent certificate journal policy.
Its one/four-row missing suffix cases do not establish complete barrier parity or the remaining fault matrix.
The pinned source's
wire participant list, its coordinator-local sequence, its retransmission
journal and its own cut selection remain open in
[#48](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/48).
Native six-player sessions cover multiple local handles per endpoint. Exported
Chromium covers a three-page WebRTC barrier after injected endpoint silence
on both pins, with independent confirmed-history checks and a corruption
control. A second case closes every RTC connection on the departed endpoint before agreement, then requires actual late direct delivery between survivors.
The lost-answer case drops one real follower inventory report and requires an exact retry before certified continuation.
Natural unequal-delivery tests preserve the needed suffix, and captured donor journals survive physical source-ring reuse.
Room/process departure, relay-delivered agreement and the remaining live fault
cases stay in
[#166](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/166).
Hot join uses reserved/dropped slots with fixed player cardinality,
bounded session-bound snapshot transfer and agreed activation frames.
It must not infer admission from SignalFish reconnection alone.

Apply feature-specific upstream models and runtime fault tests at each step.
The final advanced task audits all remaining applicable upstream behavior and
creates residual tasks before any complete-parity claim.

## Upstream tracking and upgrades

Monitor Fortress plus relevant SignalFish SDK/server contracts weekly and
manually. Maintain separate latest-observed and last-reviewed revisions.
The weekly automation is future work tracked in M2, not activated by this plan.

Classify source, constants/defaults, macros/attributes/cfg, build logic,
tests/models/fixtures, dependencies and documentation.
Token/AST analysis reduces noise but does not prove semantic equivalence.
Unknown classification, API failure or incomplete diffs require review.

Map changes to ledger entries and rerun old/new upstream scenarios.
Unchanged observed traces do not erase source-change evidence.
Dependency changes receive separate reporting and applicable checks.
Handle additions, deletions, renames and rewritten/unreachable baselines.

Update one deduplicated issue with revisions, commit links, affected tasks,
classifications, actual results and a review checklist.
Do not automatically regenerate goldens, merge updates or advance reviewed pins.
A baseline advances only after changes are ported, justified inapplicable or
recorded as intentional divergences with evidence.

## Task execution, review and planning retrospective

Every task follows this loop:
1. State its hypothesis, observable contract and relevant upstream evidence.
2. Demonstrate a meaningful failing case or negative control.
3. Implement the smallest change and run independent/differential checks.
4. Refactor or optimize only while preserving equivalence evidence.
5. Record commands, versions, seeds, measurements, limitations and conclusions.
6. Link the PR, update the parent issue and close only after acceptance passes.

Bug fixes show pre-fix failure and post-fix success; use a pre-regression baseline
when available and document when none exists.
Research tasks produce executable experiments and explicit decisions.
Risky changes receive the repository's code/adversarial reviews.
Milestones include the required retrospective and canonical guidance updates.

Planning findings are captured here and in roadmap issue #2:
- Bootstrap notes describe older assumptions; B2 audits and corrects them.
- Upstream runtime-to-TLA+ traces support scoped reuse; V5 owns proof limits.
- Binary relay differs from unreliable WebRTC; S2/S3 own separate evidence.
- Packed-buffer ownership and allocation claims require probes; R2/R3 own them.

These findings are tracked, not claimed as repaired runtime behavior.
The planning session established PLAN.md and the GitHub backlog. Subsequent
implementation evidence lives in `progress/` and the linked task issues.

## Session completion contract

Target sessions shorter than two hours and aggregate each session into one PR.
Follow [ship-session](.llm/skills/ship-session/SKILL.md): after all current-head CI
is green, scan inline threads, submitted reviews, conversation comments and check
annotations with complete pagination. Address every actionable finding, repeat
CI after fixes, and scan again immediately before merging. Squash merge the
session PR to `main` yourself: the repository owner authorizes the agent to merge it
without human review once the session is complete. Verify its merge SHA,
fetch and fast-forward local `main` to `origin/main`, then verify main CI.

Use [user-copy](.llm/skills/user-copy/SKILL.md) for comments, PR titles/bodies,
commit messages and CHANGELOG entries. Editor and formatter source line widths
are 180 characters; `make lint-source` checks every tracked source file.

## Primary references

- [Pinned Fortress source](https://github.com/wallstop/fortress-rollback/tree/d124c89080004d96971a629bb0427056ee1805e3)
- [Upstream session interface](https://github.com/wallstop/fortress-rollback/blob/d124c89080004d96971a629bb0427056ee1805e3/src/sessions/session_trait.rs)
- [Confirmed-state simulation oracle](https://github.com/wallstop/fortress-rollback/blob/d124c89080004d96971a629bb0427056ee1805e3/tests/simulation/harness/oracle.rs)
- [Handshake runtime-to-model trace contract](https://github.com/wallstop/fortress-rollback/blob/d124c89080004d96971a629bb0427056ee1805e3/specs/tla/traces/sync-handshake-v1/README.md)
- [Pinned SignalFish Godot SDK](https://github.com/Ambiguous-Interactive/signal-fish-client-godot/tree/8e1475ed12a618fb41660bd1c8a1b0c934dee77f)
- [SignalFish transport fallback contract](https://github.com/Ambiguous-Interactive/signal-fish-server/blob/8cbf5d9e5dc155e7a7a4f8f5593f0a24f8aaa560/docs/architecture/transport-fallback.md)
- [SignalFish delivery and incarnation contract](https://github.com/Ambiguous-Interactive/signal-fish-server/blob/8cbf5d9e5dc155e7a7a4f8f5593f0a24f8aaa560/docs/adr/0006-protocol-v3-delivery-reliability.md)
- [Godot packed-array ownership](https://docs.godotengine.org/en/4.3/classes/class_packedbytearray.html)
- [Godot web export constraints](https://docs.godotengine.org/en/4.3/tutorials/export/exporting_for_web.html)

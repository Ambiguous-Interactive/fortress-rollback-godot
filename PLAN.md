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
- [Session/driver/state/transport interface ADR](docs/contracts.md).
- [Verification and release evidence policy](docs/verification-policy.md).
- [Fail-closed native test runner](docs/test-runner.md).
- [Game integration guide, frame loop and confirmed one-time effects](docs/integration.md).
- [Match recording, replay files and checksum-validated playback](docs/integration.md#record-and-replay-a-match).
- [Runtime input-delay increases and their result codes](docs/integration.md#change-input-delay-during-a-match).
- [Playable input-driven shots, confirmation and prediction stalls](docs/integration.md#try-the-effects-example).
- [Playable online room setup and controls](docs/online-example.md).
- [Online suspension, elapsed-time expiry and fresh-room restart](docs/online-example.md#suspension-and-expiry).
- [Online terminal connection cleanup and fresh-room recovery](docs/online-example.md#leave-and-restart).
- [Actual server-process restart and old-room packet rejection](docs/online-example.md#verification).
- [Source-family inventory and remaining semantic audit](docs/reference/INVENTORY.md).
- [Measured packed-buffer and snapshot ownership](docs/experiments/buffer-ownership.md).
- [Measured integer and fixed-width encoding contracts](docs/experiments/integer-encoding.md).
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
Godot physics and arbitrary scene state are not made deterministic by rollback.

## Reference revisions and provenance

Research inspected these exact revisions:

| Project | Research baseline |
| --- | --- |
| Fortress Rollback | `f13cd5c0f2815926785a395947e18da0dbea0dd8` |
| SignalFish Godot SDK | `db7d30f228d8d564adcb2eb38d5983bf6b9877ac` |
| SignalFish server | `9c2fb8fa635a69241b8ccf38be651d561fef7434` |

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
| `FortressDriver` | Fulfill ordered requests synchronously through the same session engine |
| `FortressTransport` | Bounded nonblocking send/receive with identity and backpressure |

Driver and expert API must never implement separate rollback algorithms.
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
conservative remote confirmation evidence; voluntary input-idle tail convergence
is a separate compatibility decision.
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

Replay records confirmed gameplay history; diagnostic network traces are a
separate format. Both need versions, validation and reproducible provenance.
Runtime input-delay changes must preserve exact upstream scheduling behavior.

Single-host spectators precede redundant-host failover.
Coordinated peer drop must preserve exposed confirmed history and irreversible
commit semantics; a local minimum-received-frame shortcut is insufficient.
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
session PR to `main` under standing user authorization, verify its merge SHA,
fetch and fast-forward local `main` to `origin/main`, then verify main CI.

Use [user-copy](.llm/skills/user-copy/SKILL.md) for comments, PR titles/bodies,
commit messages and CHANGELOG entries. Editor and formatter source line widths
are 180 characters; `make lint-source` checks every tracked source file.

## Primary references

- [Pinned Fortress source](https://github.com/wallstop/fortress-rollback/tree/f13cd5c0f2815926785a395947e18da0dbea0dd8)
- [Upstream session interface](https://github.com/wallstop/fortress-rollback/blob/f13cd5c0f2815926785a395947e18da0dbea0dd8/src/sessions/session_trait.rs)
- [Confirmed-state simulation oracle](https://github.com/wallstop/fortress-rollback/blob/f13cd5c0f2815926785a395947e18da0dbea0dd8/tests/simulation/harness/oracle.rs)
- [Handshake runtime-to-model trace contract](https://github.com/wallstop/fortress-rollback/blob/f13cd5c0f2815926785a395947e18da0dbea0dd8/specs/tla/traces/sync-handshake-v1/README.md)
- [Pinned SignalFish Godot SDK](https://github.com/Ambiguous-Interactive/signal-fish-client-godot/tree/db7d30f228d8d564adcb2eb38d5983bf6b9877ac)
- [SignalFish transport fallback contract](https://github.com/Ambiguous-Interactive/signal-fish-server/blob/9c2fb8fa635a69241b8ccf38be651d561fef7434/docs/architecture/transport-fallback.md)
- [SignalFish delivery and incarnation contract](https://github.com/Ambiguous-Interactive/signal-fish-server/blob/9c2fb8fa635a69241b8ccf38be651d561fef7434/docs/adr/0006-protocol-v3-delivery-reliability.md)
- [Godot packed-array ownership](https://docs.godotengine.org/en/4.3/classes/class_packedbytearray.html)
- [Godot web export constraints](https://docs.godotengine.org/en/4.3/tutorials/export/exporting_for_web.html)

# Retrospective Archive: Foundations Through Server Restart

## Scope and evidence

This summary replaces 22 episodic artifacts from 2026-10-09 through 2026-10-13.
Their full findings, exact measurements, commands, scoped claims and pending-at-capture
states remain in the immutable
[historical directory](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/tree/ecf68a061142e955e87c4b1d6446b8f23a245213/.llm/retrospectives).
The filenames below identify each original artifact. For a local full-history checkout,
`git show ecf68a061142e955e87c4b1d6446b8f23a245213:.llm/retrospectives/<filename>.md`
reads its original bytes. This is an archive of evidence, not fresh verification
of historical runtime or CI claims.

## Repeated lessons and canonical homes

| Pattern established by multiple incidents | Owning guidance retained |
| --- | --- |
| A passing probe can miss its intended boundary; malformed fixtures can produce convincing unrelated reds. | [Testing triple proof](../skills/testing/SKILL.md#regression-triple-proof) requires a green single-variable control and intended-diagnostic rejection. |
| Equality and normalization erase malformed types, missing fields and invented events. | [Oracle validation](../skills/testing/references/oracle-validation.md) requires independent schemas, exact projections, nonzero named observations and semantic mutations. |
| Final state equality can hide reordered inputs, skipped rollback or absent comparisons. | The same oracle reference checks original-history prefixes; [browser integration](../skills/testing/references/browser-integration.md) checks active faults and minimum-capacity comparisons. |
| A success receipt can outlive failed reruns, stale fixtures or changes to tools and sources. | [Infrastructure evidence](../skills/testing/references/infrastructure.md) invalidates old success first and binds verified inventories before use through publication. |
| Scheduling and timeout evidence must reflect actual host time and per-peer progress. | The browser reference preserves independent observers, monotonic deadline checks, bounded diagnostics and actual host service boundaries. |
| Adapter composition and callbacks can cross an old room's ownership fence. | [Networking transport](../skills/networking-transport/SKILL.md) owns lifetime revisions, pre-transfer fences, SDK authority and terminal cleanup. |
| Bounded queues alone do not prove healthy progress, fairness or retained rollback history. | Networking and [rollback fundamentals](../skills/rollback-fundamentals/SKILL.md) own progress at accepted minima, prediction/confirmation and retention handoffs. |
| Source inventory, an engine smoke or green CI cannot prove complete runtime/browser parity. | [Ship session](../skills/ship-session/SKILL.md), product contracts and PLAN.md retain separate source, gameplay, browser, feedback and main-CI gates. |

## Original artifacts

| Filename (append `.md`) | Episode and durable home |
| --- | --- |
| `2026-10-09-devcontainer-bootstrap` | Build/lifecycle order, actual acceptance and environment facts: [devcontainer knowledge](../knowledge/devcontainer-tooling.md), adversarial review. |
| `2026-10-09-retrospective-loop` | Evidence-first curation, pruning and nonoverlapping homes: [retrospective](../skills/retrospective/SKILL.md), [harness facts](../knowledge/harness-tooling.md). |
| `2026-10-10-input-queue` | Raw/session boundary, startup divergence and artifact-layout preservation: rollback skill, [queue contract](../../docs/input-queue.md). |
| `2026-10-10-protocol-and-offline-example` | Semantic wire audit, atomic full-read restore, omission localization: networking, oracle reference, [session guide](../../docs/session.md). |
| `2026-10-10-reference-foundations` | Exit status, complete result streams, UTF-8, startup races and stale receipts: infrastructure reference and devcontainer facts. |
| `2026-10-10-representation-and-shipping` | Exact snapshot ownership and independent checksum goldens: [determinism](../skills/determinism/SKILL.md); four feedback surfaces: ship-session. |
| `2026-10-10-rollback-core` | Actual callback execution, JSON numeric conversion, guards, source bootstrap serialization and safe authenticated fallback: oracle/infrastructure references, rollback and GitHub operations. |
| `2026-10-10-runtime-oracle` | Intermediate histories, independent embedded schemas, nonempty standalone execution and semantic mutations: oracle reference. |
| `2026-10-10-stateful-oracle-and-iteration` | Exact verified-tree reuse, archive-only Cargo caches, worker isolation and packaging controls: infrastructure reference and package audit. |
| `2026-10-11-input-exchange` | Public drains, partial-publication time, active-fault canonical prefixes and source/tool identity: networking and testing references. |
| `2026-10-11-mesh-recovery-and-observation` | Exhausted-window gossip, paired service budgets, synchronous observer shutdown and per-page deadlines: networking and browser reference. |
| `2026-10-11-peer-handshake` | Parseable remote differences, retry timers, preallocation bounds and formal initial state: networking and oracle reference. |
| `2026-10-11-peer-lifecycle` | Terminal state/event agreement, exact excluded inventories, nullable ingress, minimum-capacity comparison and finalized fixtures: networking, rollback and testing references. |
| `2026-10-11-signalfish-membership` | Optional-SDK loading, additive-peer authority, atomic FIFO retry, corrected prefixes and late SDK errors: networking and browser/infrastructure references. |
| `2026-10-11-webrtc` | A-to-B-to-A lifetimes, actual channel properties, public engine APIs, pinned executable bytes and constructor orphans: networking and testing references. |
| `2026-10-12-live-fallback` | Actual addressed packet overlap, exact incarnation, independently specified rejection and early deadline callbacks: networking, oracle/browser references. |
| `2026-10-12-physical-channel-loss` | Membership-selected recipients, actual host boundaries, bounded poll batches and scoped overlap inventory: networking and browser reference. |
| `2026-10-12-transport-fallback` | Pre-transfer lifetime fencing, demonstrated-recovery clocks, per-recipient refusal and fairness: networking skill. |
| `2026-10-13-online-example` | Export resource lookup, actual terminal frontier, independent peer startup and pinned checker bytes: transport knowledge, networking and testing references. |
| `2026-10-13-online-failure-cleanup` | Physical close before user cleanup, reentrant first failure, deferred queue release and ordered observers: networking and browser reference. |
| `2026-10-13-resume-expiry` | Expiry before receive under pressure, measured suspension and monotonic timer rechecks: networking, browser reference and transport knowledge. |
| `2026-10-13-server-restart` | Later-clock foreign rejection, retained callback owners, actual process exit/readiness and typed corruption: networking and testing references. |

## Pruning and limits

The repeated testing lessons were moved intact into focused references rather
than copied into another skill. Environment facts remain in knowledge, protocol
contracts remain in networking/rollback, and shipping gates remain in ship-session.
No new skill or parallel knowledge store was created. Historical pending-at-capture
claims and follow-ups remain historical; this summary does not close them.
Current roadmap status belongs to PLAN.md and the linked task issues.

State: `findings-acted`. The archive reduces active episodic files below the
retrospective skill's approximate 15-file budget while preserving original evidence.

## Curation verification

Issue #118 requested the split and overdue distillation. Testing shrank from
299 lines to 153; infrastructure, browser and oracle references are 57, 77 and
54 lines. A line-inventory comparison confirms every nonblank moved guidance
line remains present. The green-control rule now appears before triple proof.
The active retrospective inventory drops from 33 to 12 files.

Progress cleanup retains all 32 local session files while untracking and ignoring
them. A copied candidate without `progress/` passes harness link lint. The new
boundary table fails against the original linter for local progress links and
passes the repair, while rejecting near-prefix, wrong-depth and escaping targets.
A further control with a relative repository root reproduced a false broken-link
finding; resolving the root before containment fixes it for both root spellings.
No new exemption applies outside the explicitly declared root-local directory.

Verification: `make llm-index`, `make lint-llm`, `make test-llm` and
`make lint-source`; source widths have zero violations. The session PR owns final
current-head review, CI and delivery evidence.

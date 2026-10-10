# Session 006 — Shared rollback session engine

Goal: advance PLAN.md through a green, reviewed, squash-merged session PR.
Base: `f1af76bc83a09e2ce674f8f78d06bf007cd910fa`.
Branch: `session-006-rollback-core`.
The session PR and linked task updates own final head checks, feedback scans,
merge SHA and merge-triggered main CI evidence.

## Starting audit

Clean main matched origin/main. No open or draft PR existed.
All three main workflows were green: harness 38086274321, devcontainer
38086274316 and reference 38086274319. The full open-issue audit selected
C1/C2 recovery, C3 snapshots/rollback, C4 local sync-test and C5 expert lifecycle
before maintenance or transport work. No dependency PR was open.

## Delivered runtime and contracts

The SceneTree-independent engine owns validated configuration, per-player input
queues and bounded tagged snapshot history. It exposes ordered completion with
stale/out-of-order protection, request expiry, callback failure termination and
frame commit only after full consumption. The thin game driver uses that engine.

Local sync-test executes every roster count 2–8 and compares original canonical
snapshot bytes/checksums after deliberate resimulation. Distance zero emits no
save/load callbacks; positive distance rewinds only when current exceeds distance.
External-input mode tests asymmetric global confirmation, prediction windows,
zero-window lockstep, earliest corrections and recovery-only stalls. It has no
P2P handshake, transport, protocol events or browser release claim.

Queues now reclaim only at/below a supplied global rollback floor, preserving a
bounded tagged side slot. Raw physical tags remain distinct from recoverability.
Snapshot publication is transactional; failed/stale operations preserve history.
Writer overflow, reader underflow/trailing data and invalid checksums are explicit.
Caller configuration/input/snapshot aliases cannot mutate authoritative history.

API, byte/frame domains and limits: [session guide](../docs/session.md),
[queue guide](../docs/input-queue.md), [oracle](../docs/oracle.md).

## Red-green and review evidence

The first session suite failed on missing production preloads, then passed on
Godot 4.3. New snapshot/reclaim tests likewise demonstrated missing production
APIs before implementation. These new components have no pre-regression working
version. Existing ordinary queue behavior remains under its direct Rust corpus.

A scoped fresh-context storage review passed all six applicable surfaces on both
engines. The full fresh-context session review reproduced three defects on both:
first remote nonzero input invented confirmed neutral history; terminate within
a callback permitted reconfiguration before callback return; callback input views
exposed a mutable append operation. A second full-runtime fresh-context review reported no findings.
Regressions passed after enforcing sequential remote receipt, a callback
guard independent of batch lifetime, and constructor-only input view population.
Correct-identity completion during a callback is also refused; removing that
guard reproduces premature publication. Both final fresh-context reviews completed
without findings.

Independent game tests serialize an integer LCG and pending events. Deliberately
omitting either during restore triggers localized desync even with a constant
checksum collision. Delayed correction checks every globally confirmed replay
prefix against an uninterrupted actual-input run, including non-power-of-two
input rings and repeated snapshot reuse. Driver/expert tests compare complete
callback sequences and canonical snapshots, including failures of every kind.
An isolated mutation using the fastest player's received frame as the floor
rejects valid delayed remote input in `external_corrections`; the production
global rollback-window floor, `max(0, current_frame - max_prediction_frames)`, passes.
The failure log is `.cache/tests/session-006-fast-floor-mutation.log` and #61
records the reproduction and remaining acceptance gates.

Godot 4.7.2 preserved parsed integral floats as JSON `1.0`, unlike 4.3. Strict
trace validation rejected that result. Reconstructing validated scenario numeric
fields as integers repaired serialization without weakening Python schemas.
Running two reference launchers concurrently raced their shared extraction cache;
subsequent oracle execution was sequential. No session behavior was changed to
repair either tooling boundary. A separate fresh oracle review showed substring
error projection could bless unrelated diagnostics. Exact pinned structured
shapes, canonical bounds and scenario identity now reject those diagnostics;
14 malformed shapes and one schema-valid unrelated error provide red-green proof.
A fresh full-oracle review then reported no findings; it independently ran the
711-case queues and a distance/delay 7/7 production session on both engines.

## GitHub workflow correction

The user required authenticated GitHub MCP first and authenticated `gh` CLI as
the fallback for capability gaps. Earlier ship-session guidance permitted a
read-only REST fallback without making that routing and authentication explicit.
Replaced that rule with one canonical GitHub operations skill and linked it from
context, delivery, review, copy, harness, planning and evidence guidance.
Credential handling uses existing authentication, trusted process tokens or a
configured noninteractive Git credential helper; no token output is allowed.
The initial credential search missed that helper and caused an unnecessary wait.
The helper supplied usable authentication, verified against the required endpoint,
and `gh` was authenticated using captured output and token stdin. Missing
credentials explicitly block fallback after checking these available routes. This guidance change
remains part of the same session PR.

The feedback backstop now uses authenticated `gh api`, with private debug traces
and preserved pagination headers. Missing authentication, malformed output and
redirected evidence fail explicitly. New requester controls failed before the
replacement, then passed alongside a real authenticated repository read.
All 23 feedback tests and all 97 harness tests pass. The final guidance review
reported no findings after correcting rejected-token fallback selection.

## Verification

Commands use cached minimum/current ARM64 executables under
`.cache/reference/editors/{4.3,4.7.2}/Godot_v<version>-stable_linux.arm64`.

| Gate | Observed evidence |
| --- | --- |
| Unit/core per native engine | 31 cases, 45606 assertions per in-process run after review additions; twice in each of two fresh processes |
| Production sync-test differential | 21 cases, 2352 generated requests per run, twice per engine |
| Differential roster/distance/delay | Every count 2–8; distance/delay 0/0, 2/2, 7/7 |
| Independent game/correction | 40-frame loops, PRNG/pending events, byte equality, collision and omission controls |
| Session comparator controls | Six per case, 126 per engine; invalid schema/order/state/input/stream rejected |
| Ordinary queue differential | 711 cases / 8353 operations, twice per implementation/engine; five malformed controls and isolated access-only source hook |
| Offline oracle tooling | `make test-oracle`: 18 tests, including malformed structured diagnostics |
| Harness | `make llm-index`, `make lint-llm`, `make test-llm`: 97 tests pass, including 23 feedback tests |
| Format/source | `gdformat`, `gdlint`, `make lint-source`: maximum 180 |

Receipts: `.cache/tests/session-006-all{43,472}.json`,
`.cache/reference/results/session-oracle{43,472}/receipt.json`.
Current-head CI supplies commit-bound x86_64 minimum/current and existing
Chromium/reference evidence. Local receipts record candidate source hashes and
dirty state; no complete-platform or release parity claim.

## Remaining gates and retrospective

C1–C5 remain open until their full source/applicability, property/formal and P2P
observation prerequisites are satisfied. #59 owns P2P oracle time/delivery; #61
owns remaining session-floor acceptance. #28 still needs shared Rust/Godot
PRNG/pending-event game scenarios and complete task acceptance; #29/#40 still
need P2P lifecycle, events and driver integration. Existing task issues retain
precise residual acceptance rather than copying a second checklist into PLAN.md.

Updated PLAN.md, README and canonical context to remove the obsolete claim that
all session orchestration remains planned. Testing and rollback skills now record
verified JSON typing and recovery/request-order boundaries.
Artifact: [session retrospective](../.llm/retrospectives/2026-10-10-rollback-core.md).
Retro: findings-acted

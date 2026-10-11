# Session 009 — Bounded peer synchronization

Goal: advance fixed-membership P2P with a usable byte handshake endpoint.
Base: `361378ad9e06211cbec2718b04da7c994dae8098`.
Branch: `session-009-peer-handshake`.
The session PR and linked issues own final head, feedback, merge and main-CI evidence.

## Starting evidence and scope

Clean main matched session 008's squash merge. No open/draft PRs remained.
Main workflows 38097313337, 38097313305 and 38097313419 succeeded.
The live issue audit selected #31 and the handshake slice of #59: the codec
existed, but peers could not agree on configuration or count synchronization.
This session adds that runtime behavior; it does not claim gameplay transport.

## Endpoint and byte agreement

The [handshake API](../docs/handshake.md) consumes production packet bytes,
explicit monotonic microseconds and caller-supplied tokens. Owned configuration
and identities remain immutable. Source attribution, session and connection
checks precede traffic handling. Only compatible live echoes advance roundtrips;
unknown/duplicate echoes cannot bind or poison configuration. Requests answer
without advancing synchronization. Timeout reports once and remains recoverable.

All state and queue effects publish atomically after bounded planning. Failure
preserves accepted time, queues and status. Minimum queue capacities support
begin and drained completion, including 128 roundtrips. Configuration scalars
and collection cardinalities validate before identity scans or lookup allocation.

The decoder now preserves valid remote semantic versions, feature masks and
configuration geometry within absolute caps. Endpoint policy reports precise
incompatibilities rather than misclassifying valid differences as corrupt bytes.
Independent golden-wire cases fail against the base codec and pass after repair:
`.cache/tests/session-009-codec-red.json` and `session-009-codec-green*.json`.
Gameplay packet geometry retains its negotiated limits.

## Actual source and formal observations

The [source oracle](../docs/oracle-handshake.md) executes pinned upstream public
P2P sessions with injected time and seeded protocol RNG, then drives the Godot
endpoint using actual observed tokens. Twenty-six scenarios compare complete
ordered packets, events and post-transition records twice in fresh processes.
They cover mismatch precedence/orientation, wrong sources/connections, live
echoes, reordering, duplicates, timeout recovery and one-microsecond retry bounds.
Representation mappings preserve token/connection equality and opaque digests.
The upstream semantic-version mapping is explicit; extra Godot agreement fields
remain independently tested policies.

Actual Godot transitions refine the pinned SyncHandshake TLA+ model through its
existing complete-consumption checker. The matching path consumes twelve model
rows; a duplicate-decrement mutation stalls at the intended step nine. The
second peer is a declared model environment, not a second observed Godot endpoint.
This finite three-token, small-network model omits clocks, bytes, identities,
buffer pressure and additional configuration fields. It proves no release parity.
The complete pinned static trace inventory also passes: matching (18 rows),
mismatch (4), timeout (4), and duplicate-decrement rejection (18).
Command: `verify-sync-handshake-traces.py --jar .cache/reference/tla2tools.jar`
with every pinned `specs/tla/traces/sync-handshake-v1/*.ndjson` supplied explicitly.
Receipt: `.cache/tests/session-009-upstream-handshake-formal.log`.
Default invocation first failed because its runtime producer could not locate
Cargo; this was a setup failure, not a valid negative-control verdict.

## Review repairs and negative evidence

| Finding | Repair and evidence |
| --- | --- |
| Trace milliseconds were divided twice and the absent-duration sentinel changed. | Preserve already converted milliseconds; `session-009-time-trace-red.json` fails before repair and the green receipt passes. |
| Answering a request did not refresh the retry timer as upstream queueing does. | Publish the queued reply's time atomically; request at 190 us defers a 200 us retry until 391 us. Both pins reproduce and pass the repaired boundaries. |
| Accepted transition/consumed-token minima could never complete a handshake. | Reject unusable options before initialization; `session-009-capacity-red.json` fails two configuration assertions, both pinned green receipts pass. |
| A malformed 100000-entry local roster allocated an unbounded identity lookup. | Shared validation precedes traversal; `session-009-roster-bound-red.json` measures 100004 identity checks, both green receipts measure zero without timing assertions. |
| Nullable upstream fields normalized boolean aliases and later activation records disappeared. | Strict raw schema validation and activation inventory protect full observation consumption; oracle controls own exact red/green evidence. |
| Formal projection discarded the initial observed state. | Validate the observed initialization against model Init and preserve supported send/handle post-states; actual TLC controls own exact rejection evidence. |

An isolated removed-live-echo guard fails the intended unknown-poison assertion,
with complete test results and no engine error:
`.cache/tests/session-009-echo-mutation-red.log`.
Review fixes were independently evaluated before fresh adversarial review.
The timer evaluator originally retained parsed results only in tool history.
It reconstructed isolated pre/post-repair receipts, changing only the missing
reply timestamp assignment in the red copy. These are explicitly reconstructed,
not original logs: `.cache/tests/session-009-reply-timer-{red,green}-{4.3,4.7.2}.json`.
Metadata records exact commands; red reproduces two assertions, green passes,
and all four runs complete without engine errors.
Oracle repair logs: `.cache/reference/handshake-schema-review-{red,green}.log`.
All three corruptions pass before repair and reject at their intended boundary
afterward; the permanent unit and live controls retain that coverage.

## Verification and delivery gates

The existing native/exported-Web production gate includes twenty-six cases,
both pinned engines and the original exact ownership-alias negative control.
Canonical suite ordering matches the native runner; no comparison was weakened.
Addon-only packaging runs the existing driver tick plus a real two-peer byte
handshake with no Rust or repository-test dependency.

Full native unit suites pass on both pins: 56 cases and 48668 assertions per
in-process run, repeated in-process and fresh processes. Receipts:
`.cache/tests/session-009-unit-{4.3,4.7.2}.json`. The existing determinism suites
and 42-case session/game source differential also pass on both pins.
Final native/Web receipt: `.cache/reference/results/ownership.json`.
Clean addon-only receipts: `session-009-package-{4.3,4.7.2}/package-audit.json`,
under `.cache/reference/results/`, each with 27 packaged files.
Source/GDScript lint, harness regeneration/lint and 99 self-tests pass.
Reference tooling passes 29 tests with two intentional local engine-control
skips; final CI runs the engine controls. Oracle tooling passes 30 tests.
Final handshake receipts are
`.cache/reference/results/handshake-oracle-{4.3,4.7.2}/receipt.json`.
Each records 26 cases, 128 operations, 416 corruption controls, five live malformed
fixtures, real TLC positive/duplicate rejection, and invalid-initial-state rejection.
Recorded source hashes match the frozen candidate. Fresh runtime review passes
18 focused cases and 305 independent hostile checks per engine; fresh oracle
review independently executes all 26 source cases and real TLC controls.
The separate integration/retrospective curator also reports zero issues.
Current-head CI, paginated feedback scans, squash merge, local synchronization
and merge-triggered main CI remain delivery gates recorded in the PR/issues.

#31's endpoint, differential and scoped refinement criteria are satisfied;
its closure follows verified delivery. #59 retains integrated session/mesh
requirements. #32 owns gameplay input and ACK exchange.
#30 retains full protocol integration. #34/#35–39/#41
own fault-mesh and real browser/SignalFish/client multiplayer acceptance.
No codec/handshake-only result closes those broader gates or creates duplicates.

Retrospective: [artifact](../.llm/retrospectives/2026-10-11-peer-handshake.md).
Retro: findings-acted.

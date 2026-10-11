# Session 010 — Recoverable byte multiplayer

Goal: connect real game sessions through bounded input packets and recover faults.
Base: `8d0f49ee0d2d8c4de0d676a5a8a80de04e837970`.
Branch: `session-010-input-exchange`.
The session PR and linked issues own final head, feedback, merge and main-CI evidence.

## Starting evidence and scope

Session 009 delivered the byte handshake; #32 owned the missing gameplay path.
This session adds bounded input/ACK exchange, a fixed-membership byte session,
a playable packet-fault example and actual upstream gameplay comparisons.
Real WebRTC/SignalFish delivery, pacing, checksum exchange and disconnect policy
remain #33–39. The broader release and oracle gates remain open.

## Gameplay and recovery

[Input endpoints](../docs/input-exchange.md) preserve unacknowledged history,
retry its oldest bounded prefix, apply cumulative ACKs inclusively and keep
incoming gossip separate from outgoing receipt status. Whole-body validation
precedes piggyback ACK mutation; accepted input reaches the core before its ACK.
Duplicate traffic and local sends cannot starve the independent input retry timer.

[Byte sessions](../docs/peer-session.md) reuse the shared rollback engine and
synchronous driver. Every endpoint retains the actual delayed sample before
simulation advances. Multi-link pressure preserves the accepted sample and game
frame for an identical retry. Mesh confirmation folds actual receipts and every
remote endpoint's incoming gossip. All publication queues have public drains.
Injected time is monotonic; callbacks cannot reenter mutations or drains.

A single-packet `receive_and_poll` operation uses its pre-delivery receipt bank
for simultaneous retries. Pinned `p2p_session.rs:3272–3380` services endpoints
before applying their input events to the session. Independent receive/poll
calls instead publish the post-delivery bank. Input retention still precedes ACK
publication in both paths; packet status fields remain compared exactly.

Three or more endpoint identities reject prediction zero and prediction one
without delay. Actual upstream probes reproduce their healthy gossip deadlock.
Two-identity low windows and delayed prediction one retain support. This precise
exclusion belongs in #34's supported-network-profile gate, not an expected pass.

## Playable witness

Run the [two-peer example](../docs/peer-example.md) with WASD/arrows, loss,
latency, reordering and partition controls. It uses independent byte sessions
and the existing integer simulation with complete 136-byte snapshots. Visible
frames, confirmation, pending histories, retries and restores explain recovery.
The in-process transport is bounded and does not claim internet delivery.

Active-fault tests retain loss, latency and reordering for 3,000 ticks. They
compare corrected confirmed prefixes at actual callback boundaries, against
original submitted inputs, before ledger eviction. Every peer makes nonzero
comparisons. Snapshot omission first fails at frame 5, byte 24 on both pins.
A rendered Godot 4.3 frame-120 screenshot records physical key input and the UI.

## Independent source observations

[The gameplay oracle](../docs/oracle-p2p.md) executes actual pinned upstream
`P2PSession`s and Godot byte sessions. Scenarios derive deliveries from observed
packet IDs, never inferred requests. Actual upstream compressed input is decoded
by its public decoder and independently revalidated in a second source process.

Twenty-six scenarios cover every count 2–8 at delay zero/two, plus loss,
reorder/duplicates, prediction stall/recovery and retry boundaries for 2/4/8.
Comparisons preserve ordered callbacks, current/confirmed frames, canonical
state/checksum, input statuses and every semantic input/ACK field. An independent
submitted-history prefix check rejects temporal permutations with equal finals.

Only source observations receive the declared initial-save and stall-code API
projections. Numeric lexical validation precedes Godot JSON parsing. Strict raw
schemas reject aliases; executable/source inventories are captured before use
and rechecked before success publication. Failed attempts remove prior receipts.

## Review repairs and negative evidence

| Finding | Repair and evidence |
| --- | --- |
| Scheduled delay frames were unavailable and remote startup required zero. | Expose owned scheduled samples and permit bounded neutral startup; `session-010-core-red.json` fails the delayed seam. |
| Long healthy matches exhausted an undrainable transition queue. | Add public transition drain; 400-frame regression and both-pin drain mutants protect it. |
| Partial publication left the façade clock behind mutated endpoints. | Consume valid supplied time before publication; both-pin clock mutants fail the intended assertion. |
| A stalled mesh omitted the final current-state save. | Preserve source callback inventory on stall/repair-only batches; both-pin stall-save mutants fail. |
| Assertion-green fixtures leaked their callback ownership graph. | Use weak session back-references; engine errors remain gate failures. |
| Accepted low-window meshes could not progress. | Reject precise unusable profiles; actual source probes and six red assertions establish the boundary. |
| Simultaneous four-peer retries used post-delivery gossip. | Add the combined service boundary; actual full source gates first fail at packet 16, then focused four/eight-peer retries pass. |
| Initial mesh-limit activation revoked receipt-based confirmation before advancement. | Reject every bound below published confirmation; both-pin activation regressions cover delays zero/two. |
| Oracle projections accepted null stalls, unknown statuses or later duplicate saves. | Restrict source projections and validate complete callback input status before game mutation; independent red cases precede repairs. |
| Wire projection replaced observed slots and omitted bound header identity checks. | Preserve decoded slots and validate session/sender/connection; all four real-byte mutations fail before comparison on both pins. |
| Parser canonicalization erased numeric token types and evidence identities could drift. | Reject decimal/exponent tokens and capture/recheck all executed sources/tools; live and isolated drift controls protect the boundaries. |

Negative receipts are under `.cache/tests/`; raw source divergence artifacts are
under `.cache/reference/results/session-010-p2p-final-{4.3,4.7.2}`.
These failed attempts have no success receipt and remain evidence of the repair.

## Verification and delivery gates

Final runtime adversarial review is clean. Its independent 60-iteration matrix
covers accepted windows 0/1/2/8, delays 0/1/2, counts 2–8 and multiple-local layouts.
Additional probes cover final-frame/time bounds and repeated stalled saves.
Those exploratory reviewer outputs remain in tool history; the structured
acceptance receipts below provide persistent verification.
The separate example review is clean after active-fault coverage was added.

Full unit suites pass on both pins: 82 cases and 93,064 assertions per in-process
run, repeated in-process and fresh processes. Determinism suites also pass.
Receipts: `.cache/tests/session-010-{unit,determinism}-accepted-{4.3,4.7.2}.json`.
The 48-case native/exported-Web matrix passes both pins, including intended
ownership-alias failures and positive execution: `.cache/reference/results/ownership.json`.
Addon-only audit passes 30 packaged files and three real gameplay steps on both
pins: `.cache/reference/results/session-010-package-accepted-{4.3,4.7.2}/package-audit.json`.

Existing 42-case session/game and 26-case handshake source regressions pass both
pins. Receipts are under `.cache/reference/results/session-010-{core,handshake}-accepted-{4.3,4.7.2}`.
The 26-case P2P gates and 27 live controls initially pass both pins. Fresh oracle
review independently completes that matrix and finds two remaining contract
defects: inconsistent standalone low-window bounds and broad poll error mapping.
Default scenario bounds now agree at prediction 2–8. Explicit source-only
`--profile-audit` preserves low-window measurements without a comparison receipt.
Stall projection applies only to a successful unchanged source step. The whole
poll counterexample fails at operation zero; all six original low-window audits
reproduce twice. Evidence: `.cache/session-010/oracle-profile-regression/`.
The 40-test oracle suite passes. A further wire-observer repair preserves actual
player slots and validates session/sender/connection identities. Four persistent
encoded-byte controls reproduce the original holes and reject after repair.
Final P2P receipts: `.cache/reference/results/session-010-p2p-wire-{4.3,4.7.2}/receipt.json`.
Both pass 26 scenarios, 8,394 operations, 7,653 semantic packets and 35 process
controls, with fresh Rust/Godot repeats and unchanged evidence identities.
The final oracle adversarial review is clean. It independently passes 24 extra
source/Godot comparisons with zero/max inputs, prediction 2/8, reordering,
stalls and simultaneous timestamps on both pins, plus eight actual-wire controls.
Artifacts: `.cache/reference/results/p3-adversarial-wire-final/`.
Source/GDScript lint, harness regeneration/lint, 99 harness tests, 29 reference
tests (two intentional local engine-control skips) and 40 oracle tests pass.
Current-head CI,
paginated feedback scans, squash merge and merge-triggered main CI remain
required delivery gates.

#32 closure follows complete P3 evidence and verified delivery. #33 owns pacing,
checksums and fixed-membership termination; #34 owns broad long-lived mesh,
profile, width/window and flood acceptance. #59 retains full P2P observation and
partition coverage. #41 retains actual exported-browser multiplayer and setup.

Retrospective: [artifact](../.llm/retrospectives/2026-10-11-input-exchange.md).
Retro: findings-acted.

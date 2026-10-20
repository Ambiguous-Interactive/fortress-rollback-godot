# ADR: session, driver, state and transport contracts

Status: reviewed interface contract for [B3](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/14).
This ADR settles target interfaces; [local sessions](session.md) documents the
implemented subset and its current completion signature. Transport, networking
events and first-release interfaces still require their own implementation gates.
Reference: Fortress `f13cd5c0f2815926785a395947e18da0dbea0dd8`.
The pinned baseline reproduction is B3's prerequisite. The wider applicability
audit remains a separate task; this ADR does not claim whole-library parity.

## Decision and scope

Use one session engine with two ways to consume its ordered requests: a small
synchronous game driver and an expert request interface. Both must produce the
same simulation callbacks, canonical snapshots, final frames and events for the
same configuration and input/network trace. All core types extend `RefCounted`;
none depend on `Node`, `SceneTree`, autoloads or a SignalFish installation.

The first P2P release has a fixed roster of 2–8 players. Player slots are dense,
ordered integers assigned before synchronization; transport identities map to
those slots and never renumber a live session. Sync-test permits the same roster
with every slot local. There is no automatic scene capture, late admission,
spectator mode, coordinated drop or transparent state recovery in this tier.
Loss of recoverable history terminates the session explicitly. A SignalFish
reconnect, room authority change or new transport plan cannot admit a rollback
player, replace a snapshot or reset confirmation.

## Frame and time domains

`current_frame` is the next input frame to simulate. `S(f)` is game state before
applying inputs for frame `f`: save/load at `f` refers to `S(f)`, and
`advance(f)` maps `S(f)` to `S(f+1)`. Initial state is `S(0)`.
`confirmed_frame` names the last input frame confirmed for every player; its
resulting state is `S(confirmed_frame + 1)`. `-1` means no confirmed frame,
never an index or a snapshot frame. Frame arithmetic must reject overflow;
frames are limited to `0..2147483647`, with advancement at the limit rejected
before any callback. The next session requires a new identity and initial state.

Simulation consumes whole frames only. `poll(now_us)` receives injected,
nonnegative, monotonically nondecreasing protocol time in integer microseconds;
it does not advance game state. Backward time returns `INVALID_TIME` without
changing protocol state. Tests supply time explicitly. Production obtains it
outside the core; after browser suspension it must represent actual elapsed
time, so timeout/history policy still applies. Protocol token generation is an
injected source independent of the game's snapshotted PRNG. Neither protocol
time nor token generation is accessible through simulation callback arguments.

## Typed interfaces

These signatures name target types; use [local session documentation](session.md)
for importable classes and current signatures. Godot 4.3 compatibility forbids requiring typed
dictionary syntax: use typed records and `Array[Record]` for public collections.
No public return value relies on an unexplained `Variant`.

| Type | Required operations and results |
| --- | --- |
| `FortressConfig` | Mutable setup fields; `validate() -> FortressConfigResult` creates an immutable owned validated copy or typed field errors |
| `FortressSession` | `poll(now_us: int) -> FortressResult`; `submit_local_input(player: int, sample_frame: int, bytes: PackedByteArray) -> FortressResult`; `begin_advance() -> FortressAdvanceResult`; `complete_request(batch_id: int, request_id: int, completion: FortressCompletion) -> FortressResult`; `drain_events() -> Array[FortressEvent]`; `status() -> FortressSessionStatus`; `terminate(reason: FortressError) -> void` |
| `FortressGame` | `save_state(frame: int, writer: FortressSnapshotWriter) -> FortressSaveResult`; `load_state(frame: int, reader: FortressSnapshotReader) -> FortressCallbackResult`; `simulate_frame(frame: int, inputs: FortressFrameInputs) -> FortressCallbackResult` |
| `FortressDriver` | Owns a session and game; `step(now_us: int, local_inputs: Array[FortressLocalInput]) -> FortressStepResult`; `status()` and `statistics()` report the session state and counters; drains events after processing; no separate prediction/rollback algorithm |
| `FortressTransport` | `send(destination: FortressPeerId, bytes: PackedByteArray) -> FortressSendResult`; `receive(max_packets: int, max_bytes: int) -> FortressReceiveResult`; `close() -> void` |

A `FortressResult` has a typed code and structured diagnostic fields, including
player/frame where relevant. `FortressAdvanceResult` contains a status and at
most one batch; `FortressStepResult` reports status, frame before/after and a
bounded ordered event array. A batch exposes `next_request() -> FortressRequest`
with kind, frame and a request-scoped writer, reader or input view. Completion
carries the callback result (and save checksum); no raw slot can be supplied.
Callback results return explicit success/failure.
`FortressSaveResult` additionally provides a checksum when detection is enabled.
The session lifecycle is `SYNCHRONIZING`, `RUNNING`, `TERMINATED`; sync-test starts
running. Termination is final, idempotent and exposes its original reason.

| Advance outcome | Meaning and effect |
| --- | --- |
| `READY` | Ordered batch available; the application must fulfill every request |
| `NOT_READY` | Synchronization incomplete; no batch and no simulation callback |
| `MISSING_LOCAL_INPUT` | Required local sample absent; submit it and retry; no batch |
| `PREDICTION_STALL` | Confirmed inputs too far behind; no batch and no new frame; poll and retry |
| `FATAL` | Invalid/missing recovery state, callback failure, frame exhaustion or protocol invariant failure; terminates with structured reason |

Call misuse (`BUSY`, invalid player/width/frame, stale request identity) returns
an error without corrupting the session. It is distinct from a fatal engine or
game failure. A batch abandoned without completion prevents any further
mutation until the caller explicitly terminates; it cannot be silently skipped.

## Configuration and bounds

Validation precedes allocation or transport use. Validate roster cardinality,
local-slot uniqueness, identities, fixed positive input width, neutral input of
that exact width, prediction window, input/snapshot/packet/event capacities,
timeout ordering, check distance and total storage budget. Copy all caller-owned
arrays/bytes into the validated configuration. Mutation of the original config
cannot change a session. Overflow in capacity arithmetic rejects configuration.

Audited defaults from the pinned [builder](https://github.com/wallstop/fortress-rollback/blob/f13cd5c0f2815926785a395947e18da0dbea0dd8/src/sessions/builder.rs)
and [protocol configuration](https://github.com/wallstop/fortress-rollback/blob/f13cd5c0f2815926785a395947e18da0dbea0dd8/src/sessions/config.rs):

| Setting | Initial supported default |
| --- | --- |
| Players / frame rate / input delay | 2 / 60 Hz / 0 frames |
| Maximum prediction / sync-test check distance | 8 frames / 2 frames |
| Save mode / input queue | Every frame / 128 entries per player |
| Desync detection | Enabled, interval 60 frames |
| Disconnect timeout / notification delay | 2000 ms / 500 ms |
| Successful synchronization roundtrips / synchronization timeout | 5 / 20000 ms |
| Synchronization retry / running retry / keepalive / quality reports | 200 ms each |
| Pending protocol output / checksum history / event queue | 128 / 32 / 100 entries |

Zero prediction means lockstep: advance requires every player's actual input.
Default prediction uses each slot's latest accepted actual input bytes,
independently of the session-wide `confirmed_frame`; before that slot has any
actual input, it uses configured neutral bytes. A prediction episode freezes
that value at entry, starting its bookkeeping at that slot's first missing
frame, even if the requested frame is later. Subsequent sequential arrivals
are compared against the frozen value. Matching arrivals through the last
requested frame end the episode; the first mismatch blocks further reads until
rollback resets prediction. A new episode then uses the latest accepted actual
input for that slot. For a positive limit `P`, advancement requires
`ahead < P`, where `ahead = current_frame` if confirmation is `-1`, otherwise
`ahead = current_frame - confirmed_frame`. Thus no confirmation with `P=8`
allows input frames 0–7 and stalls at 8; confirmation of input frame 0 still
stalls at 8 because `8-0 = 8`. The differential suite must preserve both
boundary witnesses.

Snapshot size, packet size and total memory budget must be supplied explicitly;
there is no guessed game-state size. Every-frame saving reserves at least
`max_prediction_frames + 1` history slots, each bounded by `max_snapshot_bytes`.
Sync-test also needs its check-distance history; validate that configured slots
cover both uses. Input queue capacity must cover delay plus retained prediction
and acknowledgement requirements. Refuse incompatible limits rather than evict
unacknowledged/recoverable data. Bounds apply separately to receive work and
transport/session queues; a packet-flood poll cannot monopolize the frame loop.
A full durable event queue terminates explicitly rather than losing fatal or
confirmation notifications; routine repeated metrics may be coalesced with a
count. This is an intentional divergence from upstream event eviction.

## Ordered requests and consumption

At most one batch is open. It has a monotonically assigned identity and requests
with ordered identities: `SAVE(frame, slot_generation)`,
`LOAD(frame, slot_generation)`, `ADVANCE(frame, inputs)`. Only the next request
can be acknowledged. Reject duplicate/out-of-order/stale completion. The batch
owns all data until completion; callers cannot edit its authoritative contents.
The engine must validate required snapshot tags before invoking game callbacks.
No poll, local submission or recursive driver/expert advancement is permitted
while callbacks or an expert batch are active. Read-only status remains usable.

The driver calls `poll`, submits each local sample, opens a batch, executes
requests in order and acknowledges each one. After complete consumption it
commits the exposed current frame, drains events, and permits presentation.
It never sorts requests or postpones a save/load. `SAVE(f)` must see `S(f)`;
`LOAD(f)` restores it; `ADVANCE(f)` consumes slot-ordered inputs and yields
`S(f+1)`. A successful step adds exactly one new frame; resimulation may perform
several extra callbacks. A stall adds no new frame. If recovery is needed before a stall can be
reported, `begin_advance` returns `READY` with a recovery-only batch whose
completion outcome is `PREDICTION_STALL`; consuming it leaves the exposed
current frame unchanged. An immediate `PREDICTION_STALL` has no batch.

On callback failure, abort the remaining requests, invalidate callback views,
mark the session terminated and expose `CALLBACK_FAILED` with request kind and
frame. There is no retry from a partially modified game. The game must restart
or restore from an application-owned known checkpoint in a new session.
Events produced during batch processing are visible only after success or
terminal failure. Simulation signals cannot control the middle of the batch.
Drain removes each event exactly once in production order; overflow policy is
explicit above. Presentation reconciles only the final state after resimulation;
confirmed effect events or stable game event identities prevent duplicate audio.

## Input and snapshot ownership

Local submission uses the current sample frame; input delay schedules it for
`sample_frame + input_delay`. Initial delayed frames use configured neutral
bytes. Submission copies fixed-width bytes before returning. A repeated
identical local sample is idempotent while stalled; a different sample for an
already accepted frame returns `INPUT_ALREADY_SUBMITTED`. Once accepted, a
sample survives stalls and is consumed only by the appropriate scheduling step.
Actual confirmed input is immutable. `FortressFrameInputs` exposes ascending
slots, owned read access and typed `CONFIRMED`, `PREDICTED`, `DISCONNECTED`
statuses; disconnected dummy inputs are specified for later advanced parity,
while loss of an active peer terminates this first fixed-membership tier.

The library owns history slot bytes, exact used length, frame tag, generation
and checksum. `FortressSnapshotWriter` offers checked writes and a cursor;
o write may exceed capacity. Saving publishes a slot only after a successful
callback with no sticky writer error. `FortressSnapshotReader` offers checked
reads of only the published length; loading succeeds only if the entire record
is consumed with no sticky reader error. Snapshot formats must include a version
and all game-authoritative data: counters, PRNG state, pending deterministic
events and any state that influences future input interpretation.

Readers/writers and input views are valid only during their request callback
(or the current expert request before acknowledgement). Retained view objects
must check generation/liveness and return `EXPIRED_VIEW` from checked operations.
The scalar input `player_count()` accessor returns `-1` when expired. `read_into`
copies into exact-width caller-owned storage and preserves it on every rejection.
Any byte array returned to user code is an owned copy; raw slot backing arrays
are never exposed. Mutating a returned copy cannot affect history. Reused slots
must check both frame and generation; modulo index alone is insufficient.

With detection enabled, `FortressSaveResult.checksum` is an owned exactly
16-byte unsigned checksum, encoded in little-endian order to represent the
upstream `u128` domain without signed Godot-int ambiguity. The game supplies a
stable algorithm over canonical snapshot content, agreed in session configuration;
algorithm identifiers and snapshot/input format versions are negotiated before
running. Missing/wrong-width checksums fail saving. Checksums are diagnostics,
not proof of byte equality; regression fixtures compare full canonical bytes.
Writer overflow, reader underflow/trailing bytes, bad tags or missing state are
explicit failures. Never truncate, substitute an empty snapshot or load a
neighboring slot. The entire simulation remains the game's responsibility.

## Transport boundary

`FortressPeerId` is an opaque stable roster identity. Incoming records carry a
transport-attributed sender and owned packet bytes; reject unknown sender/session
identity, malformed size/version and messages outside the configured bounds.
Core protocol acknowledgements/deduplication survive transport switches.
`send` returns `ACCEPTED`, `BACKPRESSURE` or `CLOSED/FAILED`. `ACCEPTED` means the
adapter owns the bytes until dispatch; it does not mean a remote peer received
or acknowledged them. On backpressure the session retains recoverable protocol
work within bounded limits; capacity exhaustion returns a typed error and
terminates if continued recovery is impossible. There is no blocking I/O.
`receive` reports bounded work plus whether more packets remain; polling follows
an explicit stable peer/order policy. The fake transport uses the same interface.

SignalFish is an optional adapter. Relay recipient envelopes, WebRTC channel
policy and path-generation validation belong there; it cannot consume core
packet streams twice or infer protocol authority from SDK room events. Rust/Godot
wire interoperability is outside scope, while supported observable rollback
behavior remains subject to the pinned differential oracle.

## Acceptance walkthroughs and negative controls

These scenarios settle B3's design acceptance and define later implementation
tests. The [local session suites](../tests/unit/test_session.gd) exercise the
implemented subset. The [fallback coordinator](signalfish-fallback.md) preserves
one live peer session across injected mixed-path tests; live browser switching
remains a separate acceptance gate.
The pre-ADR negative control is the former high-level plan: it left checksum
width, request acknowledgement, borrowed-view expiry and partial callback
failure unresolved. The decisions above settle those ambiguities for review.

| Scenario | Required trace and observation |
| --- | --- |
| Successful first tick | At `S(0)`, poll, submit sample 0 for each local slot; `SAVE(0)`, `ADVANCE(0)`; acknowledge both; expose `current_frame=1`, game `S(1)`, then drain events |
| Prediction stall | With the pinned prediction boundary reached and a remote actual input missing, preserve sample and frame; no new `ADVANCE`; poll receiving actual input permits retry without sampling a different local input |
| Rollback batch | At `S(5)`, actual frame-2 input differs: `LOAD(2)`, resimulate `ADVANCE(2..4)` with intervening saves in engine order, `SAVE(5)`, `ADVANCE(5)`; final `S(6)` equals uninterrupted actual-input oracle |
| Missing snapshot | Same correction with empty/stale slot 2: reject before `LOAD` callback; terminate `HISTORY_UNAVAILABLE`; no speculative replacement state or surviving advance |
| Failing callback | `LOAD(2)` succeeds, `ADVANCE(2)` returns error: skip every remaining request, expire all views, terminate once; recursive/repeated step cannot resume partly modified state |
| Incomplete expert batch | Acknowledge save but abandon advance: next poll/submission/advance returns `BUSY`; a duplicate save completion is rejected; only ordered completion or explicit termination resolves the batch |
| Input alias mutation | Submit `[1,0]`, mutate original to `[9,9]`; stored sample and replay remain `[1,0]`; mutate callback copy and later history remains unchanged |
| Snapshot alias mutation | Save, retain writer/reader, reuse its slot; retained operations return `EXPIRED_VIEW`; changing copied bytes cannot change a later load or checksum |
| Driver/expert parity | Feed identical trace through each API; compare ordered callbacks, canonical bytes, frame/status transitions and event order, including stall and callback failure |

Asymmetric three-player prediction witness: local A has input through frame 6,
B through 4 (value 7), and C through 1. Global confirmation remains 1. Missing
B inputs at frames 5 and 6 predict 7, rather than B's older value at globally
confirmed frame 1. Accepting B frame 5 with value 9 updates B's actual-input
base but compares against frozen 7, recording first mismatch 5; another B
input read is refused before reset. After rollback resets prediction, B frame 5
reads actual 9 and missing B frame 6 starts a new episode predicting 9. C still
holds global confirmation at 1. This witness must check status, frozen-value
comparison, first-mismatch frame, read refusal and post-reset value separately.
It follows the pinned queue's `input`, `add_input_by_frame` and
`reset_prediction` paths, rather than assuming all peers receive equal prefixes.

The integration example uses a single deterministic game implementing the three
`FortressGame` callbacks. Construct either a sync-test session (all slots local)
or P2P session (fixed local/remote roster plus transport), attach that same game
to `FortressDriver`, then at each fixed tick supply one sample per local slot to
`step(now_us, local_inputs)`. Handle nonfatal readiness/stall separately from
termination; present only after successful request consumption. Switching
session mode changes configuration/transport and input ownership, never the
save/load/simulate methods. Both modes use the same `S(f)` serialization fixtures.

## Source anchors and evidence limits

- [Unified session API](https://github.com/wallstop/fortress-rollback/blob/f13cd5c0f2815926785a395947e18da0dbea0dd8/src/sessions/session_trait.rs): input submission, polling, request return and event drain.
- [Requests, input statuses and frame domain](https://github.com/wallstop/fortress-rollback/blob/f13cd5c0f2815926785a395947e18da0dbea0dd8/src/lib.rs): typed Rust variants and signed frame sentinel.
- [Per-slot prediction and validation](https://github.com/wallstop/fortress-rollback/blob/f13cd5c0f2815926785a395947e18da0dbea0dd8/src/input_queue/mod.rs): episode entry/frozen values, sequential arrival comparisons, first mismatch and prediction reset.
- [Sync layer](https://github.com/wallstop/fortress-rollback/blob/f13cd5c0f2815926785a395947e18da0dbea0dd8/src/sync_layer/mod.rs): before-frame saves, bounded rollback and saved-frame validation.
- [Sync-test session](https://github.com/wallstop/fortress-rollback/blob/f13cd5c0f2815926785a395947e18da0dbea0dd8/src/sessions/sync_test_session.rs): shared game requests and resimulation checks.
- [P2P session](https://github.com/wallstop/fortress-rollback/blob/f13cd5c0f2815926785a395947e18da0dbea0dd8/src/sessions/p2p_session.rs): prediction boundary and protocol/session coordination.

Bounded byte callbacks, acknowledgement enforcement, lifetime checks, fatal
callback policy, fixed first-tier membership and explicit termination are Godot
API decisions, not claims that Rust exposes those exact methods. Representation,
performance and differential tests must verify these decisions before the API is
advertised. B3 requires the reviewed ADR and acceptance examples; runtime parity
and supported release claims require their separate implementation gates.

## B3 acceptance evidence

| Requirement | Decision and acceptance evidence |
| --- | --- |
| Typed, independent interfaces | Typed-interface table specifies all five boundaries; core types are `RefCounted`, and SignalFish is optional |
| Ordering, statuses and lifecycle | Advance outcomes distinguish readiness/stall/fatal; ordered-consumption rules reject reentry and incomplete batches |
| Owned inputs and bounded snapshots | Ownership section fixes width, view lifetime, tags, checksum bytes and sticky callback errors |
| Defaults and separate clocks | Pinned builder/config anchors establish defaults; frame/time section separates simulation from injected protocol time |
| Fixed first-release scope | Decision section fixes 2–8 membership, explicit history-loss termination and transport authority limits |
| Tick, stall, rollback and failure | Acceptance table walks each request sequence, missing history and callback failure |
| Mode switch and mutation | Shared-game integration example changes only configuration/transport; alias witnesses define required mutation tests |

The pre-ADR ambiguity witness above is design red evidence, rather than an
invented failing runtime implementation. The issue's design completion does
not certify future runtime classes, networking, browser execution or E1/B2.

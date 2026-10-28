# Replay session applicability

Run `make replay-probes GODOT=/path/to/pinned/godot` to compare the actual pinned
Rust `ReplaySession` and both shipped `FortressReplayPlayer` interfaces.
CI runs both engine pins. The receipt and raw logs go to `.cache/reference/results/replay/`.

The probe invokes public APIs from unchanged fortress-rollback revision
`d124c89080004d96971a629bb0427056ee1805e3`. Relevant upstream source:
[`src/sessions/replay_session.rs`](https://github.com/wallstop/fortress-rollback/blob/d124c89080004d96971a629bb0427056ee1805e3/src/sessions/replay_session.rs)
and [`src/replay.rs`](https://github.com/wallstop/fortress-rollback/blob/d124c89080004d96971a629bb0427056ee1805e3/src/replay.rs).
This is gameplay replay applicability, separate from network fault-trace replay.

## Observed contract

| Boundary | Pinned Rust | Godot |
| --- | --- | --- |
| Initial frame | Last advanced frame, initially -1 | Next frame to simulate, initially 0 |
| Input playback in this corpus | Recorded order, all statuses `Confirmed` | Same order, all statuses `CONFIRMED` |
| Unvalidated playback | One advance request per frame | One simulation callback per frame |
| Validated playback | Save request before every advance, even without a recorded checksum | Save callback only when a recorded checksum exists |
| Checksum domain | `u128` | 16 owned bytes; probe maps Rust `u128` to little-endian bytes |
| Mismatch | `ReplayDesync` event; continues advancing | `DESYNC`; stops before the mismatching advance |
| Last pre-input mismatch | Event drain after completion resolves pending validation | Checked before the final advance |
| Post-input terminal state | No recorded checksum for boundary N | Optional v6 checksum requires a final SAVE at N, without another ADVANCE |
| Completion | True after the final advance; another advance errors | v4/v5 complete after the last ADVANCE; validated v6 completes after its terminal SAVE |
| Empty replay | Complete immediately; advance errors | v4/v5 complete immediately; validated v6 checks initial boundary 0 first |

Godot callback playback dispatches the same ordered requests exposed by
`FortressReplayPlayer.configure_expert`, `begin_advance` and `complete_request`.
The probe dispatches the expert requests separately from callback playback.
Both paths must match independently computed ordered requests and state bytes.
The expert interface uses the live session
[batch and request types](session.md); validation keeps the Godot policy above.
These differences are explicit expectations; the comparator excludes no
requests, events or frame observations.

## Evidence boundaries

The 55 scenarios retain the two/eight-player zero, one and seven-frame controls,
then exercise every supported count from two through eight players for 64 frames.
Each full-roster workload runs unvalidated playback, sparse checksums and an
interior mismatch at frame 32 after a checksum-free frame. Rust must report that
exact event and continue; Godot must stop before simulating input 32. The
receipt requires all 21 long workloads independently of corpus generation;
missing workloads, missing players or shortened playback cannot qualify.
This gate checks the observed request frames independently of generated expectations.
Sparse Rust playback must save all frames from 0 through 63.
Sparse Godot callback and expert playback must save exactly the even input frames.
Version 6 also saves terminal boundary 64 before reporting completion.
The interior Godot mismatch must save frame 32 after advancing unchecked frame 31,
then stop without advancing frame 32. Every request must appear in frame order.
Disabled validation, fully populated checksums and a checked predecessor cannot qualify
as these sparse workloads.
Seed `4294967295` exercises unsigned input/state boundaries. Ordered integer
updates include a PRNG state and pending value in canonical 16-byte snapshots.

Python generates original inputs and independently computes every canonical
state boundary. Rust consumes the original rows; Godot decodes independently
packed version-4, version-5 and version-6 FRRP files. The observed decoded version must
match each workload; substituting current files cannot qualify legacy playback.
Actual save/advance callbacks, player statuses,
events, completion and failure frames must match their full expected traces.
Comparisons validate exact fields and numeric types before comparing values.
Both engines run in two fresh processes with identical results. Every scenario
runs through callback playback and separately through `configure_expert`,
`begin_advance`, batch consumption and `complete_request`: 330 Godot observations
against 55 pinned Rust scenarios. The corpus uses confirmed player statuses;
Godot's finalized disconnected-status playback has separate deterministic
coverage in `tests/unit/test_replay_drop.gd`. This comparison does not establish
upstream status-sensitive recording parity. At the pinned revision,
`Replay<I>` stores only input vectors (`src/replay.rs`, lines 109–132), and
`ReplaySession::advance_frame` assigns `InputStatus::Confirmed` to every input
(`src/sessions/replay_session.rs`, line 737). Disconnected-status preservation
is a Godot format extension, not a missing status field that this corpus can
supply to the unchanged upstream replay API.

Every frame of the version-5 or version-6 file carries the digest of its input bytes and
player statuses. Version 4 retains its byte-only digest and defaults every
player status to `CONFIRMED`. Those digests are a Godot-side integrity extension: the pinned upstream session owns the
input history and stores no such digest, so the corpus compares only the
upstream-owned behaviour and never claims parity for the digests.

Twelve paired terminal workloads cover zero, one and seven inputs with two and eight players.
Matching v6 terminal checksums require one final SAVE. A mismatch confined to the terminal checksum
must fail at boundary N after every input has run, while historical versions truthfully complete
without that evidence. The Rust adapter remains unchanged and has no post-input terminal checksum;
this is a Godot recording extension, independently calculated from the original input rows.
The separate terminal acceptance gate rejects omitted/reordered final saves, wrong final boundaries,
false completion, missing workloads and duplicate observations, even when generated expectations agree.

Negative controls mutate intermediate state while preserving the final result,
input status, frame convention, numeric type, missing/invented events and a
checksum-absent upstream save, suppressed interior mismatch and omitted middle player. Each
must fail at its independently named boundary. Six expert-only controls remove
saves, duplicate advances, alter request frames, change intermediate state or
player statuses, and advance after a failed save. Callback observations stay
unchanged in the expert-only controls. Separate controls also move the callback
or expert interior failure frame from 32 to 33. The mismatch scenarios corrupt
actual encoded checksum bytes and require Godot to stop before simulation.
Separate process controls reject oversized Rust/Godot bundle files and empty
or excessive Rust case inventories. Legacy controls substitute each interface's
decoded format, change a callback input status and omit an expert save request.
A real process control replaces the v4 bytes with valid v5 bytes and
requires rejection at the format identity boundary.

Receipts bind authored sources, verified engine archive bytes, oracle binary,
scenario files and the pinned source/lockfile identities. Source and tool hashes
must remain unchanged throughout execution. A failed attempt removes its prior
success receipt and retains raw logs.

This playback corpus does not establish recording parity; the separate
[recording comparison](#actual-recording-applicability) qualifies all-local exports.
Neither comparison establishes file interchangeability, snapshot seek acceleration or network-fault replay.
Native/browser gameplay replay evidence remains in the
[ownership experiment](experiments/buffer-ownership.md) and
[online example](online-example.md#record-and-download-a-replay).

## Dropped-player recordings on native and Web

The ownership witness also runs `test_replay_drop.gd` on both pinned native
engines and their exported Chromium builds. It records changing inputs, freezes
a departed slot below a receipt-staged tail, repairs predicted or actual rows,
then serializes and decodes the finalized version-5 recording. Callback and
expert playback must match every original status-sensitive canonical boundary;
the complete native and browser records must be identical. A failed repair
must keep its uncorrected tail private.

These cases qualify Godot playback of finalized disconnected statuses. They do
not establish upstream status-sensitive recording parity. The ownership runner
also supports the same complete replay inventory under pinned Firefox through
`--web --browser firefox`, with exact native/browser record comparison and
both control rounds for each engine pin. Firefox CI runs those rounds as
separate declared partitions; one partition alone does not qualify a pin. Its receipts identify which browser
actually ran; Chromium results do not qualify Firefox. WebKit and the remaining
cross-platform release gates in #45 remain separate.


## Final-boundary captures on native and Web

The ownership witness runs `test_replay_terminal.gd` and `test_replay_terminal_recovery.gd`
on both native pins and exported Chromium. Explicit capture uses a real bounded SAVE of the finalized
live prefix. Coverage includes empty/one-frame/capped recordings, staged samples, matching and
mismatching late input, corrected drop bytes/statuses, callback failure, overflow, cancellation and reentry.
Paired games diverge only on the last simulated input: historical files lack final evidence;
v6 fails at boundary N with expected/actual checksums. Checkpoint navigation and paused/expert
validation recheck the boundary without advancing input or duplicating checksum counts.
Capture at the recording cap preserves that original prefix; a later live state cannot replace it.
The API deliberately refuses capture until the entire simulated prefix is finalized, and does not
capture stopped peers or invent missing state. See the [capture contract](integration.md#capture-the-final-replay-state).

## Actual recording applicability

The same `make replay-probes` gate now calls the unchanged pinned
`SessionBuilder::with_recording(true)` and `P2PSession::into_replay()` APIs.
An all-local roster removes transport timing from this recording comparison.
Every supported roster from two through eight players runs zero, one, seven and
64 advances, with input delays zero and two and prediction windows zero and two: 112 cases.
The original 56 prediction-window-two workloads remain unchanged. Two explicit
56-case process partitions preserve the standalone executables' 64-case limit.
The same original samples drive a production Godot `Session` through its driver.
Both implementations serialize and decode their own resulting recordings, then
play those decoded histories through the actual replay sessions. Files remain
format-specific; the test does not convert Rust files into FRRP.

Python independently computes all original delayed rows, every canonical state,
the complete ordered original SAVE/ADVANCE request stream, exported metadata counts and checksum availability.
Original records retain every applied input value and status, every saved canonical state and
every post-advance state. Separate save and advance summaries cannot replace this ordered evidence.
It compares exact observations without excluding the source/product differences:

| Recording boundary | Pinned Rust | Godot |
| --- | --- | --- |
| Prediction two, before two advances | Empty recording | All completed, finalized inputs |
| Prediction two, after N advances, delay zero | N−1 recorded inputs | N recorded inputs |
| Prediction two, N≥2 advances, delay two | N+1 recorded inputs, including future input | N simulated, finalized inputs |
| Prediction two, delay-zero state checksums | Every exported pre-input boundary | Every exported pre-input boundary |
| Prediction two, delay-two state checksums | Initial boundary only in this workload | Every exported pre-input boundary |
| Prediction two, first save request | Two saves of boundary zero | One save of boundary zero |
| Lockstep, saves and recording checksums | No original SAVE; no recorded checksums | Same |
| Lockstep, N advances, delay zero | N recorded inputs | N recorded inputs |
| Lockstep, N≥1 advances, delay two | max(3,N+1) recorded inputs | N simulated, finalized inputs |

The source records confirmation before adding the current local samples and
before application save requests execute (`p2p_session.rs`, lines 3089–3134
and 3151–3175). Its receipt frontier can include delayed inputs beyond the
simulated state. Newly recorded future rows consequently have no saved checksum;
recording does not retroactively fill it. Godot exports only finalized simulated
history and captures completed-save checksums. Neither implementation's missing
checksum is treated as evidence of validation. The complete decoded recording is
replayed, including the source's future rows, against independently computed
states; every callback, event, completion and failure observation is compared.

Lockstep exercises a separate source scheduling boundary: confirmation is read
before local input insertion. With delay zero, each source frame requires one empty
attempt followed by its ADVANCE. With delay two, only the first attempt is empty.
Godot advances each all-local frame immediately. The adapter retains each frame's
original sample across empty source attempts, limits attempts to twice the target
advance count, and fails unless the target state is reached. Every attempt records
the actual before/after frame and ordered request kinds; empty batches cannot be
discarded or mistaken for completed gameplay. Both original gameplay histories and
their decoded replay histories match independent delayed-input states. Lockstep's
checksum-free recordings make no state-verification claim.

The receipt retains these recording observations, the 112-workload inventory and
40 paired controls. The controls remove a player, reorder inputs, change checksum
availability, shorten history and corrupt intermediate original/playback state. Additional original-request
controls change an applied input or status, corrupt saved canonical bytes, reorder SAVE/ADVANCE
and omit a SAVE while leaving exported playback untouched. Unexpected LOAD callbacks
remain in the observed request stream, including a restore that preserves canonical state.
Lockstep controls separately omit a service attempt, invent a recorded checksum,
alter an original input and claim a premature final service boundary, on both
runtimes with each delay. An independently required workload inventory rejects
removing the entire lockstep partition even if generated expectations agree.
Standalone Rust and Godot processes reject an oversized recording workload and decimal, exponent
and boolean tokens in every integer field, beside valid integer-token recording controls.
They also reject duplicate literal and escaped spellings of every recording field. Valid escaped
keys, spacing and punctuation inside string values remain accepted. The standalone inventory
contains 108 rejection controls across Rust and Godot. Number controls also reject leading zeros,
positive signs, negative values and negative zero in unsigned fields, plus malformed integer/decimal/exponent
spellings. Ordinary zero and bounded integer controls remain accepted. This validates key identity and
number spelling at the observer boundary; it does not claim a separate strict JSON parser.
Both runtime observations run twice in fresh processes under the existing
source/tool identity and minimum/current engine gates.

This qualifies all-local recording and sequential playback at prediction windows
zero and two. Remote confirmation, rollback/drop recording, recording
extraction that continues a source session, browser source comparison and the
remaining cross-platform release gates retain separate acceptance. It does not
claim complete upstream recording parity or file interchangeability.

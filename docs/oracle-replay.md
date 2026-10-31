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
zero and two. Broader remote confirmation, rollback/drop recording, recording
browser source comparison and the
remaining cross-platform release gates retain separate acceptance. It does not
claim complete upstream recording parity or file interchangeability.


## Extract a recording while gameplay continues

The same source-bound gate also invokes `P2PSession::take_replay()` midway through
56 all-local workloads. Every roster from two through eight players runs seven
and 64 advances, input delays zero and two, and prediction windows zero and two.
Extraction occurs after three or 32 completed advances. Gameplay then continues
to the original target with every original callback and canonical state compared
against independently calculated delayed inputs. The observer retains empty
lockstep service attempts too; a reported final frame alone cannot qualify.

The pinned source explicitly disables recording after `take_replay()`
(`p2p_session.rs`, lines 8398–8427). A second extraction must return the structured
`NotSupported` error. Godot's `Session.replay()` deliberately returns an owned
snapshot without disabling recording. A later Godot export must contain the
complete finalized simulated history, serialize/decode successfully, and replay
through the actual callback player against every independently computed state.
The initial export retains each runtime's recording-frontier and checksum rules
from the table above; their different extraction policies are not projected away.

Both observers decode the early recording immediately, retain both the original
export and that decoded object while gameplay continues, and compare their bytes
again afterward. Playback uses that retained decoded recording. The gate checks
every input, checksum presence, save/advance record and state boundary, not just
a successful extraction or final checksum. Both engine pins run twice in fresh
processes. Twelve paired negative controls alter continuation, retained-byte
stability, second-extraction behavior, early input, later original save state,
later Godot input and later Godot playback. Missing workloads and malformed
result versions fail separate acceptance tests.

This qualifies continuing all-local extraction and its explicit source/product
difference. Broader remote confirmation, correction/drop recording, browser source
comparison and the remaining release matrix remain open in #45.

## Remote confirmation and corrected recordings

The source-bound `replay-probes` gate also runs two actual pinned P2P sessions
through owned in-memory protocol-message sockets. Both players submit changing unsigned
32-bit inputs, advance nine frames, and deliver accumulated traffic after
rounds 1, 3, 5 and 7. Each endpoint must execute LOAD at boundaries 0, 2, 4 and
6, replay both corrected inputs, and continue with its next original sample.
The Godot observer uses the production raw `Session.receive_input` boundary;
it does not claim a second wire-protocol comparison. It injects the same
original remote rows at the same declared rounds.

Independent Python expectations calculate every original SAVE/LOAD/ADVANCE,
applied value/status, canonical snapshot and post-advance boundary. Both
runtimes export eight finalized rows, serialize and decode their own formats,
and play the decoded object through the real replay API. The ninth speculative
input stays outside the recording. Both engine pins run each workload twice in
fresh processes. A paired neutral-input workload keeps the same delivery
schedule but causes no misprediction: it must have no LOAD and no source replay
events. Withholding all receipts must fail at the prediction bound rather than
publish a success receipt. Twelve additional controls reject omitted correction,
altered original input/state, altered recorded rows/checksums and corrupt playback.
A duplicate-receipt control preserves all neutral gameplay evidence while requiring
the measured delivery count to reject the extra successful calls.

This experiment exposes a pinned-source difference. The Rust recording retains
the first, speculative checksum at odd boundaries 1, 3, 5 and 7. Those rows later
carry corrected actual inputs, so actual source playback emits `ReplayDesync`
at each odd boundary and continues. Expected and actual checksum bytes remain
in the source observation; the comparison requires these events rather than
normalizing or hiding them. Godot records the repaired checksums and its decoded
playback validates every boundary cleanly. Both original corrected histories
match the independently calculated canonical prefix.

The same gate retains those nine-frame cases and adds paired 257-frame changing-input
and neutral-input runs. Each endpoint advances beyond two default 128-row queue capacities,
executes every declared service turn, and exports exactly 256 finalized rows. The final speculative
row remains private. Changing inputs require all 128 corrections at even boundaries 0 through 254;
the neutral control requires no correction. Both decoded exports then run through actual replay.
Every original request, input/status, saved byte and resulting state remains independently compared,
including the history on both sides of queue reuse. Ten additional controls remove the correction
at boundary 128 or change the original input, exported input, playback state or delivered count after reuse.
Each must fail at its named observation; the short corpus cannot satisfy the long-run acceptance gate.
The unchanged source's default 60-frame checksum schedule contributes two additional reports at delivery
rounds 63, 123, 183 and 243. Exact delivery counts retain that traffic; it is not disabled or ignored.
Both pins run every mode twice in fresh processes. This extends the existing two-peer delivery cadence;
it does not qualify coordinated-drop recording or browser source comparison.

At the pinned revision, `P2PSession::advance_frame` assembles correction requests
and then calls `record_confirmed_inputs` before the application executes those
requests (`src/sessions/p2p_session.rs`, lines 3090–3134).
`record_confirmed_inputs` reads the existing saved-cell checksum and advances
`last_recorded_frame` (lines 8433–8491); later correction SAVE callbacks do not
replace the already exported checksum. The neutral control isolates this
ordering from the serializer or replay comparator. This is a named source
recording discrepancy tracked in [#253](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/253),
not proof of a Godot replay mismatch or complete remote recording parity. Peer drop, exported-browser source
comparison and the remaining release matrix stay open under #45.

### Asymmetric delivery and final recovery

The gate also runs changing and neutral 257-turn histories with different remote
prefixes: endpoint zero receives every two turns, while endpoint one receives every
three. This requires 128 versus 85 forward-step corrections. The independent history
checks every original callback, applied status, saved byte and exported row across two
default queue capacities. Socket delivery counts include actual INPUT, ACK and periodic
checksum traffic; checksum reports reach both endpoints at turns 65, 125, 185 and 245.

After turn 256, the fixture delivers the final missing originals without submitting
another local sample. Godot's actual `Driver.recover()` repairs one versus two pending
frames, stays at boundary 257, and exports all 257 canonical rows. Each decoded export
then validates through production playback. The neutral control has no correction.

The unchanged source has no equivalent public recovery-only entry point. Its final
poll receives the original inputs, but `advance_frame()` without a new local sample
returns `MissingLocalInput` before repair or recording. Actual `into_replay()` exports
the previously recorded 256 versus 255 rows. Their corrected original inputs remain
exact; speculative saved checksums still produce 128 versus 170 `ReplayDesync` events
under #253. Neither final polling nor export repairs the original speculative game state.
These source outcomes remain explicit observations, rather than normalized parity.

Ten mutations reject a symmetric history relabeled as asymmetric, omitted corrections,
missing final delivery, altered post-wrap exports and corrupted decoded playback at
specific diagnostics. An actual withheld-receipt control lets endpoint zero advance to
frame five while endpoint one stalls at its four-frame prediction bound. Both engines
run each changing/neutral workload twice with source/tool fingerprints and bounded
processes. This advances #256 without qualifying source recovery-only recording,
coordinated drop, browser transports or the complete #45 release gate.


The asymmetric gate also copies the actual Godot observer three times and changes one
serialized byte at frame 129 before production decoding. An altered input keeps its
original digest and stops playback before that frame's SAVE or ADVANCE. Changing one
finalized status from confirmed to disconnected also retains the original digest;
the complete decoded status matrix must show exactly that change, and playback stops
before SAVE or ADVANCE. An altered recorded checksum reaches SAVE and then stops before ADVANCE. All three report DESYNC
at boundary 129, retaining the exact original canonical state. The validator checks
the complete original file, including configuration, neutral input, every metadata field,
rows, statuses, checksums and input digests. Engine metadata comes from an independent
query of the verified executable. It then checks the single-byte
encoded difference, all decoded rows, and the complete truncated playback transcript.
This exercises real decoding and playback; the earlier JSON mutation controls remain.
An unchanged asymmetric recording supplies the green control. Forged byte evidence,
extra mutations and playback that continues cannot qualify these controls.

### Final evidence after asymmetric recovery

Separate changing and neutral asymmetric workloads call the production final-boundary
capture after recovery, without submitting a new local sample or advancing input.
Each endpoint exports all 257 original rows as version 6. The independent original
history requires one final SAVE at boundary 257, the exact terminal checksum, and
successful decoded playback through that final SAVE. Godot 4.3 and 4.7.2 each repeat
both terminal workloads with complete callback and delivery inventories.

A copied observer changes exactly one byte in the final serialized checksum for endpoint
one. The control independently reconstructs the complete original file and requires all
257 inputs to play before DESYNC at boundary 257; no further ADVANCE is allowed.
The endpoint zero control remains healthy. This qualifies Godot terminal capture after
unequal remote correction, while the unchanged source's missing recovery-only API and
speculative checksum discrepancy above remain explicit.

### Repeated prediction stalls and resumed recording

The remote gate also repeats changing and neutral 257-frame histories while endpoint
zero receives every two service turns and endpoint one receives every five. Both
endpoints reach their four-frame prediction bound repeatedly: 285 versus 286 service
attempts include exactly 28 versus 29 stalls and 257 actual forward advances each.
Samples follow the simulation frame, so retrying a stalled frame preserves its original
input instead of substituting the later service turn's input.

The independent model retains every empty/stalled attempt, ordered callback, applied
input/status, original canonical boundary, receipt and exported row through more than
two default queue capacities. Rust sends a newly queued local input even on its first
stalled call; the Godot injected-input fixture delivers completed original rows.
The model preserves these different receipt policies and Rust's extra stalled SAVE
requests. It derives actual source INPUT/ACK/checksum traffic from the serviced frames
and prior confirmation; it does not repeat the earlier fixed-cadence message totals.

Changing histories require corrections at both endpoints after queue reuse. Godot's
final recovery stays at boundary 257 and its decoded recordings validate all 257 rows.
The unchanged source exports 255 versus 256 original rows and retains its observed
speculative recording checksums under #253, including 113 versus 144 replay mismatch
events. No new local sample is supplied to repair those source recordings.

Eight mutations reject omitted stalled attempts, resampled originals, changed post-wrap
exports and delivery counts at their declared diagnostics. Actual withheld-delivery
processes stop endpoint one at frame four while endpoint zero reaches five. A separate
copied Godot observer deliberately resamples by service turn and must refuse the changed
retry; the unchanged frame-based workload is its green control. Each workload runs twice
on both engine pins. This advances #256's stalled/resumed recording evidence; transport
send refusal, source recovery-only recording, coordinated drop and browser acceptance
remain outside this witness.

The pressure gate now repeats both histories with actual final-boundary capture after
recovery. Each endpoint retains its 257 original rows, adds exactly one SAVE at
boundary 257, and decodes its version-6 recording through final checksum validation.
The full 285/286 service-attempt and 28/29 stall inventories remain required. Separate
copied observers omit each endpoint's capture, or corrupt exactly one serialized
terminal-checksum byte; all three controls reject the claimed terminal evidence.
This combines resumed recording with final-state verification on both engine pins.
It does not add source recovery-only recording or transport send-refusal coverage.

### Manual and callback recording equivalence

The asymmetric and pressure gates also execute the Godot session through its manual
request API. Each changing/neutral history runs with and without final-boundary
capture, twice in fresh processes on each engine pin. The manual consumer calls
`poll`, `submit_local_input`, `begin_advance`, `begin_recovery` and
`begin_capture_replay_boundary`, then acknowledges each actual SAVE, LOAD and ADVANCE.
It does not delegate request execution to `FortressDriver`.

The independent original-history models require the same complete callback records,
applied input/status values, service attempts, final state, exported rows/checksums
and decoded playback as the driver. A separate manual-call inventory checks every
advance result, prediction stall, recovery and capture. Recovery must keep boundary
257 without submitting another local sample. Mutations reject missing calls,
changed result codes, an extra recovery advance and altered post-wrap exports.
This comparison covers external-input core sessions; it does not add network-event
or outer peer-facade equivalence claims.

### Relay recording under sustained send refusal

`tests/unit/test_relay_recording.gd` runs three production byte sessions and relay
adapters through the SDK's public binary-send boundary. Injected SDK clients refuse
sends until every fourth, fifth or sixth service turn, respectively. Changing and
neutral histories each advance 257 original frames, through two default input-ring
capacities. Each endpoint must stall; only changing input may require rollback.

The test requires every refused FIFO head to retry with identical envelope bytes.
Each refusal must preserve queued packet/byte counts and accept no outgoing head.
It compares corrected confirmed snapshots while pressure is active, then releases
pressure and services final receipts through recovery only. Each endpoint must
export all 257 original finalized rows, with no skipped history. Every recorded
checksum and every decoded playback boundary must match the independently computed
original state. Final checksum capture and validation must leave gameplay at 257.

Run this gate with the native unit runner on either pinned engine:

```sh
python3 scripts/run_godot_tests.py --godot godot \
  --suite res://tests/unit/test_relay_recording.gd
```

The schedule has a 1,000-turn gameplay bound and 256 final recovery turns; each turn
advances injected time by one millisecond. Final service includes the endpoint's
200 ms retry interval. This is native injected SDK refusal, not actual SignalFish
server sockets or browser transport. Those release gates and unchanged-source
recovery-only recording remain open in #256; #253 preserves the source checksum
ordering discrepancy.

# Replay session applicability

Run `make replay-probes GODOT=/path/to/pinned/godot` to compare the actual pinned
Rust `ReplaySession` and both shipped `FortressReplayPlayer` interfaces.
CI runs both engine pins. The receipt and raw logs go to `.cache/reference/results/replay/`.

The probe invokes public APIs from unchanged fortress-rollback revision
`f13cd5c0f2815926785a395947e18da0dbea0dd8`. Relevant upstream source:
[`src/sessions/replay_session.rs`](https://github.com/wallstop/fortress-rollback/blob/f13cd5c0f2815926785a395947e18da0dbea0dd8/src/sessions/replay_session.rs)
and [`src/replay.rs`](https://github.com/wallstop/fortress-rollback/blob/f13cd5c0f2815926785a395947e18da0dbea0dd8/src/replay.rs).
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

This does not establish upstream recording parity, file interchangeability,
snapshot seek acceleration or network-fault replay.
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

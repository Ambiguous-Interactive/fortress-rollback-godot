# Reproduce a captured canonical window

Select **Include game state and inputs in diagnostics** before Ready in the online example. After a
failure, download diagnostics before leaving the room. Keep the original JSON
when comparing builds. The capture includes saved game state and applied inputs;
review these bytes and application metadata before sharing the file.

From this repository checkout, run the downloaded online example report offline:

```sh
godot --headless --path . --script scripts/diagnose_trace.gd -- /path/to/diagnostics.json
```

The command accepts a complete diagnostic report or its `trace` object. It loads
the shipped `fortress-online-integer-v1` simulation, restores the first retained
snapshot, and applies the recorded input bytes and statuses. It needs no server,
optional SDK, room credentials, or network connection. It never executes the
capture's descriptive `replay_command` text. Online captures now include the
command above with the default download filename, for use from this checkout.

The command prints one `FORTRESS_DIAGNOSTIC_RESULT` JSON record. Exit status zero
means the entire available window completed, with every retained canonical state
and recorded checksum matching this build. A `state` failure identifies the first
compared frame and differing byte offset. A `checksum` failure identifies the
compared frame and expected/actual checksum. Callback or snapshot failures are
reported separately and return nonzero. Invalid files also return nonzero.

For example, a report containing:

```json
{"complete":false,"validated_states":4,"advanced_frames":4,"failure":{"frame":6,"kind":"state","byte":24,"expected_bytes":136,"actual_bytes":136},"code":18}
```

means this build first produced different canonical bytes at saved boundary 6.
The restored boundary and the next three retained boundaries matched. Compare
that frame's inputs, the preceding inputs, and game version before investigating
its state fields. State at frame F precedes application of input F.

This reproduces the **local captured execution**. A clean result does not prove
that a remote peer agreed, that an application seed was originally correct, or
that the reported network mismatch is the earliest simulation divergence. A
mismatch before the retained window cannot be reproduced from that window.
The tool restores captured RNG state instead of restarting from the seed.

A capture must contain a saved initial boundary, contiguous frames, complete
per-player inputs for intermediate rows, and at least one later saved boundary.
The final row may contain only a SAVE after an unsuccessful ADVANCE. Input-only,
single-boundary, or discontinuous captures are rejected rather than silently
skipped. The final successful ADVANCE may lack a following SAVE; its result is
applied but cannot be checked. `validated_states` and `advanced_frames` distinguish
these operations. The command limits files to 1 MiB and uses the example's
136-byte snapshots, two players, and one input byte per player.

## Use another application

`FortressDiagnosticPlayer` ships in the addon and accepts the same game callbacks
as `FortressDriver`. Supply your application's matching game build and limits:

```gdscript
const DiagnosticPlayer = preload("res://addons/fortress_rollback/core/diagnostic_player.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")

var player: DiagnosticPlayer = DiagnosticPlayer.new()
var code: int = player.configure(trace, game, max_snapshot_bytes, player_count, input_width)
while code == Types.Code.OK:
    code = player.step()
var result: Dictionary = player.report()
```

Check the capture's `application_version` before configuring your game. The addon
cannot infer which application implements the captured state format. Enforce a
file byte limit before parsing your application's JSON. `configure` accepts an
already parsed trace object and owns copies of the decoded payloads. It limits
windows to 128 rows and decoded payloads to 64 MiB, independent of the capture's
claimed budgets. Snapshot and input limits come from the caller. An invalid
configuration leaves a previously configured player unchanged and calls no game
callbacks.

The first `step` restores the first boundary through a bounded reader. Every saved
boundary then calls `save_state`, requires a 16-byte callback checksum, and compares
full canonical bytes before checking the capture's optional checksum. Subsequent steps preserve captured prediction
statuses and input order. All readers, writers, and input views expire immediately
after their callback. Reentrant configuration and stepping return `BUSY`. Failure
stops playback before applying the failing row's inputs; configure again to retry.

Capture collection, privacy defaults, and memory reservations are documented in
[the trace contract](peer-lifecycle.md#opt-in-canonical-divergence-evidence).

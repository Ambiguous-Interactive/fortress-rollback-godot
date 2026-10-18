# Play a confirmed host stream

`FortressSpectatorSession` plays one trusted host's complete confirmed input rows.
It uses the same ordered expert requests and `FortressDriver` game callbacks as
player sessions. Spectators contribute no input, prediction or confirmation to
the host. This is a transport-independent playback API; live SignalFish spectator
routing, network handshake and host timeout handling remain under [#47](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/47).

## Try the local example

```sh
godot --path . res://examples/spectator/spectator.tscn
```

The upper board is a playable host with delayed remote input and actual rollback.
The lower board follows its corrected input history, twelve confirmed frames behind.
Move with A/D or arrows and fire with Space. Press P to pause only the viewer;
resume to catch up at most four frames per physics tick. R starts a fresh game.

A long viewer pause can exhaust retained host history. The viewer then stops
with `HISTORY_UNAVAILABLE`; the host keeps playing. The example runs delivery
in the same process and requires no server, SDK or native extension.

![Local host and delayed spectator](images/spectator-example.png)

## Configure the viewer

Start the game from the host's original initial state. The player count, input
width, neutral input, seed and game rules must match the host. Later admission
requires a separate agreed state-transfer contract, which this API does not supply.

```gdscript
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Spectator = preload("res://addons/fortress_rollback/core/spectator_session.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")

var config: Config = Config.new()
config.spectator = true
config.sync_test = false
config.local_players = PackedInt32Array()
config.check_distance = 0
config.max_prediction_frames = 0
config.history_slots = 1
config.max_snapshot_bytes = Game.SNAPSHOT_BYTES
config.storage_budget_bytes = config.required_storage_bytes()
var viewer: Spectator = Spectator.new()
var code: int = viewer.configure(config)
# Continue only when code == FortressSessionTypes.Code.OK.
code = viewer.set_playback(12, 4, 4)
var driver: Driver = Driver.new(viewer, Game.new())
```

The configuration requires zero input delay, zero prediction and no local players.
`queue_capacity` bounds both the per-player core queues and the extra host row
ring. The storage reservation includes both payloads and their tags; engine object
metadata remains bounded overhead, as with ordinary sessions.

`set_playback(stream_delay, max_frames_behind, catchup_speed)` holds playback
behind the highest contiguous host frame. The delay must be smaller than the
queue capacity; catch-up speed must be positive and at most that capacity.
When more than `max_frames_behind` playable frames await, `recommended_steps()`
suggests up to `catchup_speed` single-frame steps. Otherwise it suggests one.
No available frame returns zero while the host stream remains open. Gaps never
move the contiguous frontier. After a clean end, one final recommended call
publishes termination without advancing the game.

Call `driver.step(now_us, empty_local_inputs)` that many times using an explicitly
typed `Array[Driver.LocalInput]`. Alternatively, consume `begin_advance()` and
`complete_request()` manually. Each batch uses the shared session engine and
advances one frame, except the final termination call. `begin_advance()` enforces stream delay even if the caller
ignores the recommendation. Protocol time must remain monotonic.

## Deliver confirmed rows

The caller must authenticate the host, bind packets to the correct game lifetime,
and agree configuration before calling `receive_host_frame(frame, inputs)`.
The method takes one `Array[PackedByteArray]` in stable player order, copies it,
and validates every player's width before changing the buffer.

| Result | Meaning |
| --- | --- |
| `OK` | Owned row accepted, or identical retained duplicate |
| `INVALID_CONFIGURATION` | Row does not contain exactly the configured players |
| `INPUT_WIDTH` | A player's input has the wrong byte width |
| `INVALID_FRAME` | Negative, exhausted or overwritten old frame |
| `INPUT_ALREADY_SUBMITTED` | Conflicting duplicate; original row remains unchanged |
| `NETWORK_BACKPRESSURE` | Frame is beyond the bounded future window; retain and retry after playback |
| `BUSY` | A request batch or game callback is active; retry after completion |
| `TERMINATED` | Host stream ended or the session was terminated |

Rows may arrive out of order within the current bounded window. No partial row
or prediction is simulated. Rejected rows leave the accepted history unchanged.
Local input submission, per-player `receive_input` and input-delay changes return
`UNSUPPORTED`; use complete host rows.

A local `FortressSession` host can export a caller-owned row with
`confirmed_inputs(frame)`. It returns null unless the frame was simulated, is
confirmed under the host's current confirmation policy, and is outside pending
correction. It also returns null during request processing or after a physical
input tag was overwritten. Copy the returned per-player bytes into a complete
row before delivering them. Export does not extend rollback history or wait for
spectators; callers must keep their own bounded send cursor and handle missing
history explicitly. The playable example shows this loop.

## End the stream

For a known clean end, call `finish_host()`. It refuses further rows, releases
the configured viewing delay, plays the remaining contiguous prefix and then
terminates. Buffered rows beyond a gap cannot be played. Do not call it while
expecting retransmissions to fill a gap. Continue servicing `recommended_steps()`
after finishing the host, including its final terminal call. This reports
`TERMINATED`, runs no game callback, and then recommends zero further work.

On host loss, malformed authenticated transport or an unrecoverable history gap,
call `terminate(reason)`. This stops immediately, including buffered playback.
The caller owns injected-clock timeouts and physical transport cleanup.
Reconfigure with a fresh initial game to restart; no automatic reconnect or
cross-session packet acceptance is implied.

## Evidence and remaining acceptance

Native tests on both engine pins cover 2–8-player configuration, atomic malformed
rows, reordering, conflicting and identical duplicates, ring wrap, storage bounds,
stream delay, catch-up, clean and failed host endings, frame exhaustion, expired
views, and manual/driver request equality. The local game example compares every
viewer state with independent original-input game history while the host rolls
back. Pausing and history loss leave host progress unaffected.

This foundation does not close #47. Actual upstream spectator differential/model
checks, host protocol events, SignalFish spectator identity/routing, real relay
delivery, and network lifecycle validation remain required. The existing player
mesh roster must not be extended to admit spectators without those contracts.

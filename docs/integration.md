# Add rollback to your game

This guide covers what your game must provide and how to call the library each frame.
The code lives in [`examples/integration/`](../examples/integration/):

- [`game.gd`](../examples/integration/game.gd): two players move left/right and fire shots.
- [`loop.gd`](../examples/integration/loop.gd): one local player against one remote player.
- [`effects.gd`](../examples/integration/effects.gd): plays each shot's sound exactly once.
- [`integration.tscn`](../examples/integration/integration.tscn): playable shots with delayed remote input.

[`test_integration_example.gd`](../tests/unit/test_integration_example.gd) runs this code with late remote input,
prediction stalls and rollback. It compares the result with a straight replay of the actual inputs.

## Try the effects example

```sh
godot --path . res://examples/integration/integration.tscn
```

Move with **A/D** or the **arrow keys** and hold **Space** to fire. The blue player follows scripted inputs.
Press **1**, **2** or **3** for remote-input delivery delays of **0**, **3** or **12** physics ticks.
Press **R** to restart with the selected delay and a fresh effects ledger.
Press **P** to pause and watch a replay of the confirmed frames so far. It starts from a fresh game,
checks every recorded checksum and ends on the corrected state. Press **P** again to return to the match.
This example delivers input in process and needs no server or SignalFish SDK.

Hollow flashes show recent shots from the current, corrected simulation. Prediction can create a flash
that disappears when the remote player's actual input arrives. Filled pulses below each lane represent
one-time confirmed effects; each is labeled with its stable shot ID. They wait for confirmation and correction,
then play once. The effect counter never rewinds or counts resimulation as another shot.
At 12 ticks of delay, the eight-frame prediction window fills and movement waits for input.
The queued input, rollback-load and stalled-tick counters show that recovery continues.
Changing delay preserves already queued deliveries; reducing delay can take time to clear the old queue.

`demo.gd` drives the same game, loop and effects ledger as the guide. It keeps a bounded delivery queue
and a bounded recent-effects history. The renderer reads corrected state after each step, including a stall
that corrected earlier frames. Its filled pulses replace audio so the confirmation behavior is visible without speakers.

![Playable rollback-safe shots](images/integration-effects.png)

To run it from a clean project containing only the addon and this example, run from the repository root:

```sh
DEMO_DIR=$(mktemp -d)
mkdir -p "$DEMO_DIR/addons" "$DEMO_DIR/examples"
cp project.godot "$DEMO_DIR/"
cp -R addons/fortress_rollback "$DEMO_DIR/addons/"
cp -R examples/integration "$DEMO_DIR/examples/"
godot --headless --path "$DEMO_DIR" --editor --import
godot --path "$DEMO_DIR" res://examples/integration/integration.tscn
```

Use a Godot 4.3 or newer executable for both commands. No Rust toolchain or native extension is needed.

## Install

1. Use Godot 4.3 or newer.
2. Copy `addons/fortress_rollback` into your project's `addons` directory.
   It needs no editor plugin, autoload, Rust or native extension.
3. Set **Physics > Common > Physics Ticks Per Second** to **60** and call the library from `_physics_process`.

Preload `core/config.gd`, `core/session.gd` and `core/driver.gd`.
Online play adds a transport: see the [byte session guide](peer-session.md).
The [online example setup](online-example.md#install-and-run) creates a separate project,
installs the optional SDK, configures a local server, exports Web and hosts HTTPS/WSS.
It includes a missing-SDK check before adding online dependencies.

## What your game provides

Your game is an object with three methods. The driver calls them; your game never calls them itself.

| Method | Contract |
| --- | --- |
| `save_state(frame, writer)` | Write the complete state for `frame`. Return `Driver.SaveResult.new(ok, checksum)`. |
| `load_state(frame, reader)` | Read a snapshot back. Return `false` if it is invalid. |
| `simulate_frame(frame, inputs)` | Read every player's input with `inputs.read(player)` and advance exactly one frame. |

`current_frame` is the next frame to simulate. Saving frame F stores the state before input F.
Simulating input F produces the state for frame F + 1.

### Inputs

Each player's input is a fixed number of bytes, the same for every player and frame.
Pack buttons into bits: the example uses one byte with left=1, right=2 and fire=4.
Configure `input_width` and a `neutral_input` of that width; neutral input fills frames before the first real input.
Never send floats, strings or engine objects as input. Quantize analog sticks to small integers first.

### Snapshots

A snapshot must contain **everything** the next frame reads: positions, timers, cooldowns,
random-number state, pending events and any event log. A missing field passes in single-player
testing and then desyncs after the first rollback.

- Use fixed-width integers in a fixed order. The example writes 64-bit little-endian fields.
- Start with a format version and the frame number.
- In `load_state`, read the whole snapshot, call `reader.is_complete()` to reject trailing bytes,
  and validate every field **before** changing any game state.
- Return a 16-byte checksum, or set `checksums_enabled = false`. Peer sessions exchange checksums to detect desyncs.
- Set `max_snapshot_bytes` to your snapshot size and `storage_budget_bytes` to `config.required_storage_bytes()`.

### Simulation

Simulation must give identical results on every machine. Use integers or fixed-point math.
Keep random-number state in the snapshot and advance it only from `simulate_frame`.
Do not read the clock, `delta`, engine physics, node positions or the global random generator.
Avoid float math in simulation: results can differ between platforms.
`simulate_frame` must not play audio, spawn nodes or send messages.

## The frame loop

Call `driver.step(now_us, samples)` once per physics frame with one `Driver.LocalInput` per local player.
Peer sessions call `FortressPeerSession.step` with the same arguments and add two results.
`now_us` comes from `Time.get_ticks_usec()` and only drives session timers. The simulation never sees it.

| Step result | Meaning and what to do |
| --- | --- |
| `OK` | The game advanced one frame. Update presentation. |
| `PREDICTION_STALL` | Remote input is too far behind. The frame did not advance, but earlier frames may have been corrected. Update presentation and retry next frame **with the same input bytes**. |
| `NETWORK_BACKPRESSURE` | Peer sessions only: drain outgoing packets, then retry with the same input bytes. |
| `NOT_SYNCHRONIZED` | Peer sessions only: the connection handshake has not finished. Keep polling. |
| Anything else | If `session.status().lifecycle` is `TERMINATED`, the session stopped: show `reason` and `failure_frame` and offer a restart. Otherwise the call was rejected, for example `INPUT_ALREADY_SUBMITTED`; fix the call. |

Sample local input once per frame. While stalled, keep submitting that same sample:
a different sample for the same frame is rejected with `INPUT_ALREADY_SUBMITTED`.
`loop.gd` keeps the sample until the frame advances.

For a local driver, you can connect `driver.step_completed(code, frame_before, frame_after)`
to update presentation after all callbacks finish. It also runs after a repair-only stall,
when the frame number stays the same but the corrected game state has changed.
Keep this handler for presentation: recursive calls to this driver return `BUSY`.
Peer callers can use `peer.step_completed` with the same scalar arguments.
It runs after peer control processing too. Mutating peer calls return `BUSY`
until handlers return; drain peer packets, events and transitions after `peer.step` returns.

A failed callback stops the session for good. Do not keep stepping a stopped session. Configure it again or create a new one.

## Presentation and effects

Rollback runs `simulate_frame` again for frames it has already shown. Anything done inside
the simulation can happen more than once, or for input that turns out to be wrong.

**Draw from current state.** After each `OK` or `PREDICTION_STALL`, read the corrected state and draw it.
Interpolate between the previous and current frame for smooth motion; use floats only for drawing.
See the [offline example](offline-example.md#presentation-after-rollback).

**Play one-time effects only after confirmation.** `session.status().confirmed_frame` is the latest frame
whose inputs are final for every player. A predicted shot can disappear when the real input arrives.
Sounds, score popups, achievements and network messages cannot be undone, so `effects.gd` plays a shot only
when its frame is confirmed and already corrected. Each shot has a stable ID derived from its frame and player.
The ledger remembers the highest ID played, so a shot never plays twice.

Call `reconcile` after each step. Remote input can raise `confirmed_frame` before the next step runs the rollback.
The ledger therefore also skips frames at or after `status().pending_rollback_frame`.

The test shows why this matters. Prediction repeats a player's last known input.
Suppose the remote player releases fire, but the release arrives late.
Predicted state can then show a shot that was never fired.
A ledger that plays shots as soon as they appear plays those wrong shots.
The confirmed ledger plays each actual shot once, on the first frame it becomes final.

If an effect must start immediately, such as a muzzle flash, draw it from current state so rollback can remove it.
Keep snapshotted event records long enough for presentation to confirm them: `game.gd` sizes its shot ring
from the prediction window.

## Test for desyncs early

Run your game in a sync-test session before going online. Sync-test keeps every player local,
rolls back `check_distance` frames on each step after the first `check_distance` frames and compares the resimulated snapshots.

```gdscript
var config := FortressConfig.new()
config.check_distance = 4
config.max_snapshot_bytes = MyGame.SNAPSHOT_BYTES
config.storage_budget_bytes = config.required_storage_bytes()
```

A snapshot that leaves out state stops the session with `DESYNC` and a `failure_frame`.
The test drops the shot cooldown from the snapshot and confirms sync-test catches it.
The [offline example](offline-example.md) is a complete sync-test scene.

## Record and replay a match

Set `config.replay_max_frames` before `configure` to record confirmed inputs as the match runs.
Recording keeps the first frames and stops when full. At 60 frames per second, 216000 frames
cover an hour; memory is about `replay_max_frames * (player_count * input_width + 17)` bytes,
outside `storage_budget_bytes`.

```gdscript
config.replay_max_frames = 216000
# ... play ...
var bytes: PackedByteArray = session.replay().to_bytes()  # or peer.replay()
```

`session.replay()` returns a copy holding every frame whose inputs are confirmed and already simulated.
Predicted input is never recorded. Each frame also keeps the state checksum when the session still had it.
`skipped_frames()` counts frames recorded as neutral input because their real input was unavailable.
It stays zero in normal play; treat a nonzero count as an incomplete replay.

To watch it, start from the same initial game state and step a `FortressReplayPlayer` once per physics frame:

```gdscript
var replay := FortressReplay.new()
if not replay.decode(bytes):
	return  # truncated, corrupt or from an unsupported format version
var player := FortressReplayPlayer.new()
player.configure(replay, MyGame.new(), MyGame.SNAPSHOT_BYTES)
```

`step()` calls `simulate_frame` with the recorded inputs and returns `OK`, then `FRAME_EXHAUSTED` after the last frame.
With a positive snapshot size it first calls `save_state` and compares the recorded checksum.
`DESYNC` means this game build simulates differently from the recording one; playback stops at `failure_frame()`.
Pass `0` to play inputs without checking. The file stores inputs, not game rules or seeds:
keep your own game version and setup alongside it.

## Change input delay during a match

Input delay trades responsiveness for fewer rollbacks. Set the starting value with `config.input_delay`.
A player on a worse connection can raise it mid-match:

```gdscript
var code: int = session.set_input_delay(player, session.input_delay(player) + 1)  # or peer.set_input_delay
```

Call it between steps or while stalled, never from a game callback. Each added frame repeats the
player's latest input, so a held button stays held for those frames. Peers receive the added frames
as ordinary input and stay in agreement. Replays record them like any other input.

| Result | Meaning |
| --- | --- |
| `OK` | The new delay applies to the next sample. Asking for the current delay is also `OK`. |
| `UNSUPPORTED` | A decrease after the first sample. Peer sessions also refuse changes before the first step and with several local players. |
| `INVALID_CONFIGURATION` | `delay + max(max_prediction_frames, check_distance) + 2` exceeds `queue_capacity`. Peer sessions allow at most `FortressPeerSession.max_input_delay(config)`, which leaves room for every peer's delay. |
| `NETWORK_BACKPRESSURE` | A peer still holds too many unacknowledged frames to send the added ones. Try again later. |
| `INVALID_PLAYER` | The slot is not a local player. |
| `NOT_SYNCHRONIZED` / `BUSY` / `TERMINATED` | The peer session is not running, a step or callback is in progress, or the match has ended. |
| `PROTOCOL_FAILED` | Sending the added frames failed. The match ends rather than let peers disagree. |

Before the first sample, a plain `FortressSession` accepts any delay that fits, including a lower one.
Give every peer the same `queue_capacity`. The handshake does not compare capacities yet: a peer with a
larger one can raise past the other peer's limit, and that match ends with `PROTOCOL_FAILED`.

## Coming from Rust

The concepts match [fortress-rollback](https://github.com/wallstop/fortress-rollback).
Differences in this port:

| Rust | Godot port |
| --- | --- |
| `SessionBuilder` | `FortressConfig`, then `session.configure(config)` |
| `add_local_input` + `advance_frame` requests | `driver.step(now_us, samples)` calls your three methods in order |
| `SaveGameState` / `LoadGameState` / `AdvanceFrame` | `save_state` / `load_state` / `simulate_frame` |
| Game state cells holding Rust values | Your own byte format through bounded readers and writers |
| `PredictionThreshold` error | `PREDICTION_STALL` result |
| `with_recording` + `into_replay` | `config.replay_max_frames`, then `session.replay()` |
| `set_input_delay` / `input_delay` | Same names on sessions and peer sessions; result codes replace `FortressError` |
| `ReplaySession` with validation | `FortressReplayPlayer`; a checksum mismatch stops playback with `DESYNC` instead of queuing an event |

The manual request API remains available: see the [session guide](session.md#expert-request-consumption).
Rust and Godot peers cannot join the same session, and replay files are not interchangeable. Spectators,
dropping peers mid-game and joining mid-game are not available yet; the [plan](../PLAN.md) tracks them.

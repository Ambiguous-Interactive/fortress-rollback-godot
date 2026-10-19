# Play a confirmed host stream

`FortressSpectatorSession` plays one trusted host's complete confirmed input rows.
It uses the same ordered expert requests and `FortressDriver` game callbacks as
player sessions. Spectators contribute no input, prediction or confirmation to
the host. The playback API and optional byte envelope are transport-independent; live SignalFish
spectator routing and network handshake remain under [#47](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/47).

## Try the local example

```sh
godot --path . res://examples/spectator/spectator.tscn
```

The upper board is a playable host with delayed remote input and actual rollback.
The lower board follows its corrected input history, twelve confirmed frames behind.
Move with A/D or arrows and fire with Space. Press P to pause only the viewer;
resume to catch up at most four frames per physics tick. R starts a fresh game.

A long viewer pause can exhaust retained host history. The viewer then stops
with `HISTORY_UNAVAILABLE`; the host keeps playing. The example encodes and receives spectator byte packets
in the same process, with an injected ten-second host deadline. It requires no server,
SDK or native extension. The example sends keepalives on ticks without accepted rows,
including initial prediction and viewer backpressure.

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
Local input submission, per-player `receive_input`, input-delay changes and
player-mesh `set_confirmation_limit` calls return `UNSUPPORTED`; use complete host rows.
Viewer confirmation follows the host rows consumed by playback. Player confirmation
gates cannot withhold those rows from `confirmed_inputs` or change viewer confirmation.

A local `FortressSession` host can export a caller-owned row with
`confirmed_inputs(frame)`. It returns null unless the frame was simulated, is
confirmed under the host's current confirmation policy, and is outside pending
correction. It also returns null during request processing or after a physical
input tag was overwritten. Copy the returned per-player bytes into a complete
row before delivering them. Export does not extend rollback history or wait for
spectators; callers must keep their own bounded send cursor and handle missing
history explicitly. The playable example shows this loop.

## Publish from a host

`FortressSpectatorPublisher` owns a bounded host send cursor and one prepared packet.
Configure it with the host session, agreed 32-byte identity and maximum packet size.
It starts at frame zero and exports only corrected, simulated, confirmed inputs.
The local example uses this publisher for its byte delivery.

```gdscript
const Publisher = preload("res://addons/fortress_rollback/core/spectator_publisher.gd")
var publisher: Publisher = Publisher.new()
var code: int = publisher.configure(host_session, agreed_identity, 65536)
var packet: Types.InputResult = publisher.prepare_packet()
# On OK, pass packet.bytes to the authenticated transport.
# Only after transport acceptance:
code = publisher.acknowledge_packet(packet.bytes)
```

`prepare_packet()` returns `PREDICTION_STALL` when no corrected confirmed row is
available. On `OK`, the caller owns the returned bytes. Refusal needs no acknowledgement;
the next preparation returns the identical retained packet while continuation remains possible. A mutated or stale
acknowledgement returns `STALE_REQUEST`, preserving the cursor. Acceptance moves
`next_frame()` once. Transport acceptance does not prove delivery; reliable delivery
or retransmission remains the caller's responsibility.

One retained row survives eviction from host history. If later required history
is overwritten, preparation reports `HISTORY_UNAVAILABLE` even before retrying a retained head; it never skips a missing
row. Source reconfiguration fences prepared packets even when dimensions match.
Active host requests and callbacks return `BUSY` before publisher mutation.
Host termination stops publication; finish clean publication before terminating the host.

`encode_keepalive()` remains independently available while a row is refused.
Send these authenticated liveness packets before the receiver deadline during pauses
or transport pressure. They do not acknowledge, replace or advance a pending row.

Stop the host, finish any correction and confirm its entire simulated tail before
calling publisher `finish_host()`. It freezes the exclusive end and returns
`PREDICTION_STALL` if correction or confirmation remains incomplete. Continue preparing
and acknowledging rows; END follows the final row. Once END is accepted, preparation
returns `TERMINATED`. Keep the host stopped and configured until publication finishes. If it advances
past the frozen end, preparation and acknowledgement return `INVALID_FRAME`;
keepalive encoding returns empty bytes.
Each preparation and acknowledgement does bounded work for at most one packet.
There is no recipient membership, authentication, transport queue or automatic reconnect.

## Deliver bytes over a caller-owned transport

`FortressSpectatorStream` wraps a spectator session with versioned fixed-width packets.
Configure it with the spectator `config`, an owned 32-byte identity, initial monotonic
microseconds, a positive timeout, and a packet limit large enough for one complete row.
Use `playback_session()` with the ordinary driver and fresh initial game state.

```gdscript
const Stream = preload("res://addons/fortress_rollback/core/spectator_stream.gd")
var stream: Stream = Stream.new()
var code: int = stream.configure(config, agreed_identity, 0, 2000000, 65536)
# Continue only on OK. Authenticate host delivery before accepting packets.
var viewer: Spectator = stream.playback_session()
code = stream.receive_packet(received_bytes, now_us)
code = stream.poll(now_us)
```

The identity contains a 16-byte session ID, eight-byte host ID and eight-byte
connection lifetime. Identifiers fence delivery; they do not authenticate a sender.
The caller must authenticate the host and agree neutral input, seed, initial state
and game rules separately. Use fresh identities for a new network lifetime.

Reconfigure through `stream.configure` when starting another viewer lifetime.
If you configure the returned playback session directly, the existing stream loses
authority over it. Packet delivery and polling then return `INVALID_CONFIGURATION`;
row, END and keepalive encoders return empty bytes. Old packets and deadlines
cannot change the replacement viewer. A failed viewer configuration preserves
the existing stream. Explicit stream configuration installs a fresh viewer;
use a fresh initial game, driver and agreed connection identity with it.

The 48-byte little-endian header contains `FRGS`, version 1, kind, player count,
reserved zero byte, u32 input width, the identity, and a u32 frame. `encode_row`
appends exactly one complete row in stable player order. Obtain that row from the
host's corrected `confirmed_inputs`; the encoder cannot prove it was confirmed.
`encode_end(final_frame)` carries the exclusive final frame without a body.
`encode_keepalive()` uses kind 3, a reserved zero frame, and no body. It refreshes
host liveness without adding inputs, advancing playback, or completing an END gap.
Send it before the deadline when no row can be delivered, including confirmation
stalls, game pauses, or viewer backpressure. Poll the viewer independently.

ROW (kind 1) and END (kind 2) retain their existing version 1 bytes. Keepalive is
an optional extension to this experimental envelope. Older receivers reject kind 3;
callers must agree support before sending it. There is no capability negotiation.
Keepalive delivery requires the same authenticated host and lifetime as input rows.

`receive_packet` validates lengths, version, dimensions and identity before touching
playback. Foreign or malformed packets return `PROTOCOL_FAILED` without changing
the session. Conflicting accepted history terminates the viewer. Reordering and
identical retained duplicates use the same bounded row ring as direct delivery.
No extra receive queue is retained. On `BUSY` or `NETWORK_BACKPRESSURE`, keep the
exact packet and retry after the active batch or playback frees capacity.

Call `poll` independently of playback and packet acceptance. The deadline uses
elapsed time since the last accepted host packet; expiry wins over a packet at
that exact deadline and terminates with `PROTOCOL_FAILED`. Calls during an active
batch return `BUSY` without changing clocks. Rejected packets do not refresh host
liveness. A valid keepalive obeys the same strict deadline, monotonic clock, and BUSY rules. A clean END may overtake rows: remaining rows below its exclusive bound
are accepted until the contiguous prefix is complete, then playback drains cleanly.
A missing tail expires when the host stops delivering accepted packets. Keepalives
prove host liveness; they do not repair missing history. The caller must terminate
a known unrecoverable gap. The caller owns transport closure.

This envelope is separate from the player wire protocol. It supplies neither
handshake negotiation, retransmission nor SignalFish spectator admission. Player
rosters and player confirmation remain unchanged.

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
stream delay, catch-up, input-idle keepalives, clean and failed host endings, frame exhaustion, expired
views, and manual/driver request equality. The local game example compares every
viewer state with independent original-input game history while the host rolls
back. Pausing and history loss leave host progress unaffected.

This foundation does not close #47. Actual upstream spectator differential/model
checks, host protocol events and handshake, SignalFish spectator identity/routing, real relay
delivery, and network lifecycle validation remain required. The existing player
mesh roster must not be extended to admit spectators without those contracts.

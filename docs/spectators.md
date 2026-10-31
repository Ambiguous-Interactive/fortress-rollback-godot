# Play a confirmed host stream

`FortressSpectatorSession` plays one trusted host's complete confirmed input rows.
It uses the same ordered expert requests and `FortressDriver` game callbacks as
player sessions. Spectators contribute no input, prediction or confirmation to
the host. Complete rows carry input bytes and finalized `CONFIRMED` or `DISCONNECTED`
status for every player. Playback preserves those statuses, including when a game
changes behavior after graceful drop. The playback API and optional byte envelope
are transport-independent; live SignalFish
spectator routing and network handshake remain under [#47](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/47).

## Try the local example

```sh
godot --path . res://examples/spectator/spectator.tscn
```

The upper board is a playable host with delayed remote input and actual rollback.
The lower board follows its corrected input history, initially twelve confirmed frames behind.
Move with A/D or arrows and fire with Space. Press P to pause only the viewer;
resume to catch up at most four frames per physics tick by default. Press N to pause and inspect
one confirmed viewer frame at a time. Each press advances at most one frame and still
respects the viewing delay; it waits when confirmed inputs are unavailable.
Press [ or ] to lower or raise the viewing delay by one confirmed frame, including while paused.
Press comma or period to lower or raise the catch-up limit by one frame per tick.
The limit ranges from one frame through the configured queue capacity; it changes neither
viewing delay nor pause. The label shows the selected limit.
Reducing delay catches up within that work limit; raising delay waits for
more confirmed input without rewinding. The label shows the selected delay.
These controls never advance or sample the host. Restart restores twelve frames of delay
and the four-frame catch-up limit.
The label also counts contiguous buffered confirmed frames and later rows beyond gaps,
including while paused. Later rows become buffered only after their missing earlier inputs arrive;
they cannot be played yet. These counts show the current backlog independently of the selected delay.
The host continues playing during inspection. E stops the host at its current
frame, waits for outstanding actual inputs, repairs its final state and sends a clean end.
A paused viewer can resume or press N through the final tail to display that exact final state.
After the last frame, press N once more to report completion.
The viewer shows `BUFFERING` at startup while it waits for enough confirmed input to preserve
its delay. A paused final tail shows `FINAL TAIL PAUSED` and the resume/step controls.
Press L to simulate a known loss of the viewer's host connection. Buffered viewer
frames stop immediately, including while paused, and the last displayed state remains.
The host keeps playing. R starts a fresh game after completion or connection loss.
Viewer failures keep their original reason through later ticks, single-frame inspection,
completion callbacks and independent host failures. A failed viewer never displays a clean
completion message just because its next operation reports a generic stopped result.
Plain cancellation shows `STOPPED`; only fully serviced clean host endings show `COMPLETE`.
Restart retires the prior host and viewer, including retained driver and stream handles.
An active callback or expert request batch must finish before restart, another tick,
single-frame inspection, viewing-delay or catch-up adjustment, or clean host ending can succeed. These actions return `BUSY`
without consuming time, changing playback controls or stopping the viewer.
This control reports known loss directly to the spectator session; it does not
close a real network connection or simulate elapsed host timeout.

A long viewer pause can exhaust retained host history. The viewer then stops
with `HISTORY UNAVAILABLE` and the R restart control; the host keeps playing. The example encodes and receives spectator byte packets
in the same process, with an injected ten-second host deadline. It requires no server,
SDK or native extension. The example negotiates the envelope version before its
first row and sends keepalives on ticks without accepted rows,
including initial prediction and viewer backpressure.

![Local host and delayed spectator](images/spectator-example.png)

## Save the viewed history

Press V to save `fortress-spectator.frrp`: browsers download the file; native builds
save it under `user://` and show the full path. The example records the first ten
minutes of viewed input, including finalized player statuses. It does not record
host frames the viewer has not played. Saving leaves host gameplay and viewing
controls unchanged.

A live or paused save captures the displayed state boundary through the ordinary
driver SAVE callback. A clean ending captures that boundary before the viewer
terminates, including a match with no input frames. Loading the bytes with
`FortressReplay.decode()` and playing them with `FortressReplayPlayer` and the
[example game](../examples/integration/game.gd) reproduces the viewed state.
Open the saved file in the [replay viewer](online-example.md#record-and-download-a-replay),
which selects the spectator game from its explicit recording identity. The same
playback, input inspection, backward navigation and checksum checks apply.
Older spectator exports without a game identity remain refused; save a new recording.

![Saved spectator replay with Fire input inspection](images/spectator-replay.png)

The demo's `replay_bytes()` returns owned portable bytes. It returns empty while
callbacks or expert requests own the match, before startup, or when an empty
failed viewer has no captured state. After connection loss or missing history,
it exports the prefix already viewed; it never promotes buffered host input into
played history. A final checksum exists only if that exact boundary was captured.
After ten minutes, export retains the first ten minutes without claiming the
later displayed state was recorded. Restart clears the old recording.

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

`viewer.playback_status()` returns an owned observation without consuming input,
advancing clocks or draining lifecycle events. It includes `current_frame`,
`host_frontier`, `buffered_frames`, `playable_frames`, `pending_frames`,
`missing_frame`, `recommended_steps`, `input_closed`, `state`, `code` and `reason`.
Buffered and playable counts describe only the contiguous prefix at the playback boundary.
`pending_frames` counts all accepted unplayed rows, including later rows beyond gaps.
`missing_frame` identifies the first gap before those accepted rows, or `-1` when no gap is known.
An empty pending buffer means the viewer is waiting for new host progress, rather than a known missing row.
The local example names the missing frame and later-row count while it buffers.
These observations do not request retransmission or establish host liveness.

![Viewer waiting for a missing frame while retaining later input](images/spectator-gap.png)

`PlaybackState.WAITING_FOR_INPUT` means no contiguous row is available.
`DELAYED` means received rows are held by the viewing delay; `PLAYABLE` means
at least one row passes that delay. `FINAL_TAIL` means clean input closure released
the delay. Its zero-frame state still needs the recommended terminal service call.
`COMPLETE` requires that call; `STOPPED` also covers cancellation, failure and an
unconfigured viewer. Stopped viewers report zero playable frames, even when
retained buffered rows remain. `code` reports readiness, including `BUSY` during
an active request and `NOT_CONFIGURED` before startup; `reason` preserves the
committed cause independently. Reading during `BUSY` retains potential frame counts
without granting permission to step. Pause remains application-owned, so a paused
`FINAL_TAIL` can show resume controls without claiming playback has completed.
Rejected reconfiguration preserves the observation; successful configuration starts
a new lifetime. The local example uses this API to distinguish a mid-match input
wait from ordinary viewing delay.

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
`playback_policy()` returns the current `[stream_delay, max_frames_behind, catchup_speed]`.

Call `driver.step(now_us, empty_local_inputs)` that many times using an explicitly
typed `Array[Driver.LocalInput]`. Alternatively, consume `begin_advance()` and
`complete_request()` manually. Each batch uses the shared session engine and
advances one frame, except the final termination call. `begin_advance()` enforces stream delay even if the caller
ignores the recommendation. The catch-up rate stays the caller's: take the reported
number of steps per service cycle. Protocol time must remain monotonic.
Playback never guesses a row. If the retained host row for the current frame is gone,
the advance is refused with `HISTORY_UNAVAILABLE` and no game callback runs.

## Deliver confirmed rows

The caller must authenticate the host, bind packets to the correct game lifetime,
and agree configuration before calling `receive_host_frame(frame, inputs, statuses)`.
The method takes one `Array[PackedByteArray]` and one `PackedByteArray` of statuses
in stable player order. It copies the complete row and validates every input width
and status before changing the buffer. Omit statuses, or pass an empty array,
for the byte-only API's all-`CONFIRMED` default. Pass explicit statuses when
streaming a dropped match; equal input bytes can still have different simulation behavior.

| Result | Meaning |
| --- | --- |
| `OK` | Owned row accepted, or identical retained duplicate |
| `INVALID_CONFIGURATION` | Wrong player/status count or a non-final status |
| `INPUT_WIDTH` | A player's input has the wrong byte width |
| `INVALID_FRAME` | Negative, exhausted or overwritten old frame |
| `INPUT_ALREADY_SUBMITTED` | Conflicting duplicate; original row remains unchanged |
| `NETWORK_BACKPRESSURE` | Frame is beyond the bounded future window; retain and retry after playback |
| `BUSY` | A request batch or game callback is active; retry after completion |
| `TERMINATED` | Host stream ended or the session was terminated |

Rows may arrive out of order within the current bounded window. No partial row
or prediction is simulated. Rejected rows leave the accepted history unchanged.
Local input submission, per-player `receive_input`, input-delay changes, player freezing and
player-mesh `set_confirmation_limit` calls return `UNSUPPORTED`; use complete host rows.
`validate_player_freeze` also returns `UNSUPPORTED`, matching the unsupported freeze operations.
Viewer confirmation follows the host rows consumed by playback. Player confirmation
gates cannot withhold those rows from `confirmed_inputs` or change viewer confirmation.

A local `FortressSession` host can export a caller-owned row with
`confirmed_inputs(frame)`. It returns null unless the frame was simulated, is
confirmed under the host's current confirmation policy, and is outside pending
correction. It also returns null during request processing or after a physical
input tag was overwritten. Copy both the returned per-player bytes and statuses into a complete
row before delivering them. Export does not extend rollback history or wait for
spectators; callers must keep their own bounded send cursor and handle missing
history explicitly. The playable example shows this loop.

## Publish from a host

`FortressSpectatorPublisher` owns a bounded host send cursor and one prepared packet.
Configure it with the host session, the agreed 32-byte identity, the agreed 32-byte
key, the agreed 16-byte configuration digest and the maximum packet size.
It starts at frame zero and exports only corrected, simulated, confirmed inputs.
The local example uses this publisher for its byte delivery.

```gdscript
const Publisher = preload("res://addons/fortress_rollback/core/spectator_publisher.gd")
var publisher: Publisher = Publisher.new()
var code: int = publisher.configure(host_session, agreed_identity, agreed_key, agreed_digest, 65536)
# The startup exchange comes first.
var offer: PackedByteArray = publisher.encode_offer()
# Send the offer, then the viewer's answer:
code = publisher.receive_accept(viewer_answer_bytes)
var packet: Types.InputResult = publisher.prepare_packet()
# On OK, pass packet.bytes to the transport.
# Only after transport acceptance:
code = publisher.acknowledge_packet(packet.bytes)
```

`encode_offer()` returns one authenticated startup offer that names the envelope
version and the optional kinds the host can publish. The viewer answers it with
its own accept packet; `receive_accept()` validates that answer and records the
agreement. The answer is authenticated with the shared key, so a peer cannot
choose a weaker envelope without it. An answer that names another envelope
version within the capability-mask range or an optional kind outside the offer is refused with `UNSUPPORTED`, and
the host publishes no row afterwards. `agreement_state()`, `agreement_version()`,
`agreement_kinds()` and `agreement_reason()` report the agreement and its one
recorded refusal reason. Before the agreement, `prepare_packet()` returns
`NOT_SYNCHRONIZED` and `encode_keepalive()` returns empty bytes: an unagreed
host publishes nothing.

Version zero and versions above 31 are malformed and return `PROTOCOL_FAILED`.
They leave the agreement pending so a corrected authenticated answer can still complete startup.

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
Every published packet carries the keyed tag that the viewer verifies, so a packet
that did not come from a host holding the agreed key is refused.
There is no recipient membership, transport queue or automatic reconnect.

## Deliver bytes over a caller-owned transport

`FortressSpectatorStream` wraps a spectator session with versioned fixed-width packets.
Configure it with the spectator `config`, an owned 32-byte identity, the agreed
32-byte key, the agreed 16-byte configuration digest, initial monotonic
microseconds, a positive timeout, and a packet limit large enough for one complete row.
Use `playback_session()` with the ordinary driver and fresh initial game state.

```gdscript
const Stream = preload("res://addons/fortress_rollback/core/spectator_stream.gd")
var stream: Stream = Stream.new()
var digest: PackedByteArray = Stream.configuration_digest_with_state(config, "seed-1", "rules-1", original_snapshot)
var code: int = stream.configure(config, agreed_identity, agreed_key, digest, 0, 2000000, 65536)
# Continue only on OK.
# The startup exchange comes first:
code = stream.receive_packet(host_offer_bytes, now_us)
var answer: PackedByteArray = stream.encode_accept()
# Send the answer to the host.
var viewer: Spectator = stream.playback_session()
code = stream.receive_packet(received_bytes, now_us)
code = stream.poll(now_us)
```

The identity contains a 16-byte session ID, eight-byte host ID and eight-byte
connection lifetime. Identifiers fence delivery; the key authenticates the sender.
The packet limit must fit the largest packet the envelope produces: the startup
exchange is 88 bytes and a complete row is the header plus one sample and
one status byte per player.
The key is a shared secret that never travels in a packet. The digest binds the
agreed match: the player count, the input width, the neutral input, the seed and the
rules version. For network startup, use
`Stream.configuration_digest_with_state(config, seed, rules_version, original_snapshot)`
on both sides. Supply the game's complete canonical initial snapshot, before frame zero,
not its current state or a checksum. The helper also binds those bytes, so equal seeds
cannot hide different original worlds. It rejects snapshots above `config.max_snapshot_bytes`
before hashing and returns an owned 16-byte digest. It neither transfers nor restores the snapshot;
the caller must configure its game from exactly those agreed bytes before playback.

The state-bound digest is the first 16 bytes of SHA-256 over ASCII `FRGS-INITIAL-STATE-v1`,
the legacy 16-byte configuration digest, the snapshot byte count as little-endian u32,
and the snapshot bytes. An explicitly empty snapshot has its own state-bound digest.
The three-argument `configuration_digest` retains its historical bytes for existing callers,
but does not bind an original state. Mixing the helpers fails startup agreement.
The seed and the rules version travel as printable ASCII,
so both sides agree on one encoding. A digest helper returns empty bytes for a
configuration it cannot describe, and the stream then refuses to configure. Use fresh identities and a fresh key for a new network
lifetime, and derive a fresh digest for a new match.

Reconfigure through `stream.configure` when starting another viewer lifetime.
Successful replacement terminates the old viewer, so retained drivers cannot play its buffered rows.
Rejected or BUSY configuration preserves the existing viewer.
The new viewer keeps your playback policy when it still fits the new ring; a policy that
no longer fits falls back to the session defaults.
If you configure the returned playback session directly, the existing stream loses
authority over it. Packet delivery and polling then return `INVALID_CONFIGURATION`;
row, END and keepalive encoders return empty bytes. Old packets and deadlines
cannot change the replacement viewer. A failed viewer configuration preserves
the existing stream. Explicit stream configuration installs a fresh viewer;
use a fresh initial game, driver and agreed connection identity with it.

The 80-byte little-endian header contains `FRGS`, version 3, kind, player count,
reserved zero byte, u32 input width, the identity, the 16-byte configuration digest,
a u32 frame and the 16-byte keyed tag. The tag is an HMAC-SHA256 of the header and
the body under the shared key, truncated to 16 bytes; it sits between the header and
the body, so a row body keeps its fixed offset. `encode_row`
appends all player samples in stable player order, followed by one status byte
per player in the same order. `CONFIRMED` is 1 and `DISCONNECTED` is 3;
`NONE` (0), `PREDICTED` (2) and other values are refused. Omitted statuses default to all-confirmed.
The tag authenticates both the samples and statuses. Obtain that row from the
host's corrected `confirmed_inputs`; the encoder cannot prove it was confirmed.
`encode_end(final_frame)` carries the exclusive final frame without a body.
`encode_keepalive()` uses kind 3, a reserved zero frame, and no body. It refreshes
host liveness without adding inputs, advancing playback, or completing an END gap.
Send it before the deadline when no row can be delivered, including confirmation
stalls, game pauses, or viewer backpressure. Poll the viewer independently.

ROW (kind 1), END (kind 2) and keepalive (kind 3) share the version 3 envelope.
Version 3 adds finalized row statuses to the authenticated version 2 envelope.
Versions 1 and 2 remain frozen and are refused at startup; there is no automatic
downgrade that could lose disconnected status. Update both host and viewer together. The envelope version and
the optional kinds are negotiated before the first row, so a peer that speaks
another envelope fails at startup instead of at the first packet. Keepalive
delivery requires the same key and lifetime as input rows.

`receive_packet` validates lengths, version, dimensions, identity, configuration
digest and tag before touching playback. Foreign or malformed packets, packets
signed with another key and packets for another agreed match return
`PROTOCOL_FAILED` without changing the session and without refreshing host
liveness. Conflicting accepted history terminates the viewer. Reordering and
identical retained duplicates use the same bounded row ring as direct delivery.
Authenticated rows older than playback whose history has expired return `OK`
without changing playback or renewing host liveness. This policy applies to
every byte transport; retained conflicting rows still terminate the viewer.
No extra receive queue is retained. On `BUSY` or `NETWORK_BACKPRESSURE`, keep the
exact packet and retry after the active batch or playback frees capacity.

Call `poll` independently of playback and packet acceptance. The deadline uses
elapsed time since the last accepted host packet; expiry wins over a packet at
that exact deadline and terminates with `PROTOCOL_FAILED`. Calls during an active
batch return `BUSY` without changing clocks. Rejected packets do not refresh host
liveness. A valid keepalive obeys the same strict deadline, monotonic clock, and BUSY rules. A clean END may overtake rows: remaining rows below its exclusive bound
are accepted until the contiguous prefix is complete, then playback drains cleanly.
While that final tail remains playable, identical retained rows, the same END,
keepalives and identical startup offers remain idempotent. They cannot reopen input.
Authenticated contradictions still terminate the viewer; forged packets stay inert.
Actual playback termination rejects later delivery with `TERMINATED`.
A missing tail expires when the host stops delivering accepted packets. Keepalives
prove host liveness; they do not repair missing history. The caller must terminate
a known unrecoverable gap. The caller owns transport closure.

This envelope is separate from the player wire protocol. It supplies envelope negotiation
but no retransmission, initial-state transfer or SignalFish spectator admission. Player
rosters and player confirmation remain unchanged.

## Negotiate the envelope before the first row

`stream.host_status()` separates host liveness from playback progress. Its owned dictionary reports
`observed_time_us`, `liveness_time_us`, `timeout_remaining_us`, `end_frame`, `missing_frame`, `input_closed` and `code`.
The clock is the last accepted injected protocol time; reading never polls, drains events or renews host liveness.
The liveness baseline starts at configuration and refreshes on accepted host traffic, including keepalives.
Obsolete rows outside retained history do not refresh it. Remaining timeout is measured at that observed clock,
not wall-clock time. Keep calling `poll(now_us)` independently of playback to observe elapsed time.

`end_frame` exposes an authenticated exclusive END immediately, even when missing inputs prevent closure.
`missing_frame` identifies the first missing row before accepted later rows or that END; `-1` means no known gap.
`end_frame = -1` means no authenticated END has arrived.
This lets a client distinguish recovery of final input from an open host stream. A complete clean tail sets
`input_closed` and disables expiry with `timeout_remaining_us = -1`; it still requires ordinary playback to finish.
Check `code` before using the observation: it reports mutation readiness, including `BUSY`, `TERMINATED` and replacement rejection.
Unconfigured or replaced viewers report unknown timestamps, deadline and frame fields as `-1`, with input closure false.
The SignalFish viewer adapter exposes the same observation under `relay.status().host` only for its attached playback lifetime.
Detached adapters or replaced streams/viewers return an empty host dictionary until a fresh attachment succeeds.
An attachment that changes during a status read also leaves that call's host observation empty; read again for the fresh lifetime.

Startup offers and their retries obey the same monotonic clock, strict host deadline,
active-request guard and terminal lifetime as row delivery. An offer arriving at the
deadline expires the viewer before agreement; a retry cannot reopen a clean end.
`encode_accept()` returns empty bytes after viewer termination or during an active
request or callback. Retry after the active operation completes; a failed viewer needs
a fresh stream. A delayed control handoff must not start publication for a stopped viewer.

The host offers the envelope version and the optional kinds it can publish with
one `OFFER` packet (kind 4). The viewer answers with one `ACCEPT` packet (kind 5).
Both packets carry the same 80-byte header, the same keyed tag and an eight-byte
capability body: a u32 version mask and a u32 kind mask. The agreed envelope
version is the version byte of the accepted packet.

- The viewer accepts an offer when the offered kinds are known, carry the
  mandatory row and end kinds, and the two sides share at least one envelope
  version. It answers with the highest shared version, so a host that offers
  several versions is not forced onto a version the viewer cannot speak.
- The host accepts an answer only when it names a version the host offered and
  kinds inside the offer that keep the row and end kinds. The optional keepalive
  kind may be dropped, so a viewer that does not want liveness packets never
  receives one. A refused answer is terminal, and an answer that differs from
  the accepted one cannot move an agreed host.
- A refusal is explicit and happens before any row is played. The viewer reports
  `UNSUPPORTED` for another envelope version or an unknown optional kind, and
  `PROTOCOL_FAILED` for a forged, foreign or malformed packet. The reason is
  recorded in `agreement_reason()`, the agreement state becomes `REFUSED`, and
  the viewer terminates, so a partial playback never starts. A refused
  agreement is terminal: it never agrees again.
- The exchange is authenticated with the shared key, so an unauthenticated
  exchange cannot move the agreement to a weaker envelope. The envelope version
  of a row is read after the keyed tag, so only an authenticated peer can
  refuse the envelope.
- A retried offer repeats the same agreement and refreshes the host liveness,
  so a lost answer does not expire a viewer that is still negotiating. A
  different offer is a protocol failure.

`agreement_state()` reports `PENDING` before the exchange, `AGREED` after it and
`REFUSED` after it fails. A row, an END or a keepalive that arrives before the
agreement is refused with `NOT_SYNCHRONIZED`, and the publisher publishes no row
before it. Historical version 1 and 2 bytes stay frozen; a format change requires
a new envelope version with its own golden.

## Observe playback lifecycle

`viewer.drain_events()` returns owned `Spectator.Event` objects. Each event has
`kind`, `frame` and `reason`; `frame` is the playback boundary at the transition,
or the failing request frame. `reason` is `OK` except for terminal events.

| `Spectator.EventKind` | Meaning |
| --- | --- |
| `WAITING_FOR_HOST` | Successful configuration starts a fresh viewer at frame zero. |
| `SYNCHRONIZED` | The first complete contiguous host input prefix is available. |
| `HOST_FINISHED` | Clean input closure releases the delayed tail for playback. |
| `TERMINATED` | Playback reached its clean final boundary, or failed with the recorded reason. |

These events describe local playback. `SYNCHRONIZED` does not establish a network
handshake, host authentication or game-state transfer. Reordered future rows do
not synchronize a viewer until the gap at frame zero is filled. An empty clean
stream publishes input closure and termination without inventing an input prefix.

Each kind occurs at most once per configured lifetime, so the queue retains at
most four events even when the caller never drains it. A successful configuration
starts a fresh queue; a rejected configuration preserves pending events.
Returned events belong to the caller and cannot change viewer state.

Ordinary driver calls drain these events into `Driver.StepResult.events`. Consume
that result when using the driver; expert callers drain the viewer after completing
the request batch. Draining during an active batch, game callback or completion
handler returns an empty array and preserves pending events. Cancellation from a
completion handler remains queued until every handler returns.
Expiry, conflicting history and callback failures publish their exact committed
terminal cause. Repeated termination cannot replace it or publish another event.

`HOST_FINISHED` does not mean playback has completed. A paused viewer still owns
its delayed tail; only the terminal event after final playback reports completion.
`viewer.is_complete()` becomes true only on that ordinary clean terminal call.
It stays false after cancellation, host loss or callback failure, including cancellation
at the final input boundary before the terminal call. Successful configuration resets it.
Continue servicing the viewer through that final call, including an empty stream.

## End the stream

For a known clean end, call `finish_host()`. A gap before an accepted later row
returns `PREDICTION_STALL` without closing input or publishing `HOST_FINISHED`.
Deliver the missing rows and retry. On success, it refuses new rows, releases
the configured viewing delay, plays the full retained tail and then terminates.
Continue servicing `recommended_steps()`
after finishing the host, including its final terminal call. This reports
`TERMINATED`, runs no game callback, and then recommends zero further work.
The final call also completes cleanly at the frame or request-token limit;
it does not allocate another frame or request batch. Unfinished playback at
either limit still terminates with `FRAME_EXHAUSTED`.

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

The version 3 envelope has an independent golden for the whole packet, including
the keyed tag, computed outside the engine. Negative controls refuse a row signed
with another key, a changed body that keeps the old tag, a packet that carries
another agreed configuration digest, and a foreign identity, and none of them
changes the accepted history or the host liveness clock. A conflicting row that
keeps a valid tag still terminates the viewer, so the tag does not replace the
history check.

The startup exchange has its own negative controls. A version 1 peer is refused
before any row is played: the viewer records `UNSUPPORTED` for the frozen
version 1 bytes and for a version 1 offer, the host records `UNSUPPORTED` for a
version 1 answer, and the viewer terminates without a partial playback. An
offer that names an unknown optional kind is refused the same way. An offer
signed with another key is a protocol failure and agrees nothing. A retried
offer repeats the agreement and a different offer terminates the viewer. Frozen
version 2 packets are refused; version 3 has its own complete-packet golden.

An independent finite playback model checks 120 seeded byte-delivery schedules:
queue capacities 2, 3 and 5, zero and maximum delay, duplicate and reordered rows,
caller-owned retries, and END arriving before or after its tail. It compares every
played prefix with the original host transcript and checks unchanged host confirmation.
Separate controls reject loss, foreign liveness and conflicting history. Bypassing the
production delay gate fails the model's first service-advice comparison.
These bounded schedules establish neither upstream model equivalence nor live transport support.

This foundation does not close #47 or #131. Actual upstream spectator differential/model
checks, host protocol events and handshake, SignalFish spectator identity/routing, real relay
delivery, and network lifecycle validation remain required. The existing player
mesh roster must not be extended to admit spectators without those contracts.

The [native SDK spectator relay qualification](reference/spectator-relay-qualification.md)
records the historical dependency drill and the current native Fortress witness.
Exported Fortress spectator games retain their separate acceptance gate.

## SignalFish viewer ingress

`FortressSignalFishSpectatorRelay` is a receive-only bridge from the SDK's
`game_data_binary_received` signal to an existing `FortressSpectatorStream`.
Attach it after a spectator baseline, with the agreed host UUID and bounded
receive options. It requires v3 `spectator_relay`, raw `message_pack`, and a
currently connected SDK spectator role. No player membership is created or changed.

The bridge checks SDK sender attribution and the stream's authenticated match
identity before retaining bytes. It owns copies, bounds packets, bytes and work,
and polls elapsed host expiry before processing its queue. Playback pressure
retains the exact refused row and scans other queued packets within its work budget,
so a future row cannot block the earlier rows needed to free playback capacity.
One new keepalive can overtake queued rows so a paused or full viewer still observes
host liveness. Further keepalives join the bounded scan until an ordinary packet
succeeds; continuous heartbeats cannot keep an eligible original row waiting forever.
Authenticated late rows that playback already consumed and the bounded ring evicted
are discarded without reporting peer failure or refreshing host liveness. Retained
conflicting rows and malformed past or current rows keep their validation errors.
Capacity overflow ends playback explicitly and releases retained packets.
SDK frame and buffer limits must keep fitting the agreed packet ceiling, including
128 bytes of inbound framing allowance. An incompatible runtime change retires playback with `TOO_LARGE` before queued history is delivered.
Connection loss, room replacement, identity changes and stream replacement retire
that delivery lifetime. The selected host's `player_left` or `player_reconnected`
notification immediately stops buffered playback and expires active request views.
Another player's departure or reconnection leaves the viewer running. Retained callbacks from a detached bridge cannot deliver
into a later configuration. Call `poll(now_us)` even while playback is paused;
`detach()` also terminates the owned viewer. SDK getters may report a lifetime change
synchronously. Old polls and packets stop before touching replacement playback;
recursive polling returns `WRONG_STATE` without terminating the current viewer.

After the authenticated END and final playback termination, relay polling returns
`OK` with `peer_code == TERMINATED`. Queued and late packets are discarded without
turning completion into a transport failure. SDK lifetime changes still fence the
bridge. Only `viewer.is_complete()` establishes clean playback completion. Cancellation
remains a failure even at the final boundary, before the clean terminal service call,
including an empty match. Actual playback failures remain failures too.

SDK identity getters and configuration properties must return stable values without
changing previously observed identity or configuration fields. The bridge compares
two complete configuration-and-identity observations before installation or service.
This bounded check detects observed changes; it cannot make arbitrary mutating
getters atomic. Lifetime signals, detach and replacement remain supported during reads.

```gdscript
const SpectatorRelay = preload("res://addons/fortress_rollback/transport/signalfish_spectator_relay.gd")

var relay: RefCounted = SpectatorRelay.new()
var limits: RefCounted = SpectatorRelay.Options.new()
limits.max_packet_bytes = 1024
var code: int = relay.configure(client, sdk_config, protocol_info, stream, agreed_host_uuid, limits)
```

This boundary has deterministic public-interface doubles, including
canonical playback, strict deadline equality, bounded pressure and stale lifetimes.
The [native Fortress witness](reference/spectator-relay-qualification.md#fortress-native-witness)
executes this bridge through real SDK/server sockets and a separate authenticated
loopback acceptance service. Exported-browser Fortress acceptance remains open.

Spectator relay is read-only. The qualified SDK refuses spectator
`send_game_data_binary` calls. Receiving an authenticated OFFER stages one
acceptance packet. Pass an optional sender to `relay.poll(now_us, send_accept)`
to hand it to a separate authenticated control transport. The callback takes
an owned `PackedByteArray` and returns an `Error`: `OK` releases the retained
packet; `ERR_BUSY` and `ERR_OUT_OF_MEMORY` preserve its exact bytes for retry.
Other errors or malformed returns terminate the owned viewer with `SDK_FAILURE`.
`status().accept_pending` reports the one fixed-size negotiation packet retained
separately from the bounded incoming queue. Without a sender, callers can still
use `stream.encode_accept()` and arrange delivery themselves.

The adapter invokes the sender at most once per poll, after checking host expiry.
It defers callbacks during active playback requests. A refused gameplay row does
not block control delivery. Room loss, stream replacement, and detachment fence
the callback result; replacing the bridge inside a callback preserves the new
viewer. The sender is supplied for each poll and is not retained by the adapter.

Transport acceptance does not prove host receipt. The separate control path must
deliver the authenticated bytes to `publisher.receive_accept()` before that
publisher emits rows. If an accepted packet is lost afterward, retransmit the
host's OFFER: each repeated valid OFFER stages the same acceptance again.
The adapter never sends through the SDK spectator role or assumes host agreement.
The native witness provisions initial state and returns acceptance through a bounded
loopback control fixture. Production application admission, exported-browser relay
acceptance and complete source/model comparison remain in #131 and #47.

## SignalFish host publication

`FortressSignalFishSpectatorHost` connects a confirmed player session to the SDK's
public `send_game_data_binary` method. Configure it in a connected finalized room
for one pre-admitted viewer UUID. It requires the same v3 capability and raw binary
format as viewer ingress. It does not admit spectators or change player membership.

```gdscript
const SpectatorHost = preload("res://addons/fortress_rollback/transport/signalfish_spectator_host.gd")
var publication: RefCounted = SpectatorHost.new()
var limits: RefCounted = SpectatorHost.Options.new()
limits.max_packet_bytes = 1024
var code: int = publication.configure(client, sdk_config, protocol_info, player_session,
    admitted_viewer_uuid, fresh_identity, private_key, agreed_configuration_digest, limits)
```

Provision the original state, neutral input, seed, rules and complete dimensions
through an authenticated application service before attaching either side.
The bridge sends OFFER repeatedly until that service delivers the viewer's ACCEPT
through `publication.receive_accept(authenticated_viewer_uuid, bytes)`.
The UUID must match the admitted viewer; packet authentication alone does not
establish admission. This method returns a transport result with `peer_code`
carrying the publisher's specific validation result. The SDK spectator role never
sends game data.

Call `publication.poll(now_us)` with monotonic microseconds. Each poll bounds SDK
send attempts and socket buffering. Refused rows retain their exact bytes until
transport acceptance; missing overwritten history reports `HISTORY_UNAVAILABLE`
in `peer_code`. A host request already active at entry returns `BACKPRESSURE`
without accepting the supplied clock; complete it and resume from the last accepted service time.
An SDK buffer getter that opens a host request defers publication
with `BACKPRESSURE`; complete the request, then retry at the same clock time.
No OFFER, row or END is sent during that request. Due keepalives take turns with refused ROW or END packets, including with one
send attempt per poll. A refused heartbeat yields the next attempt to the payload.
Stop advancing the host, call `finish_host()`, then continue polling to publish the
remaining confirmed prefix and END. An unconfirmed tail or pending correction returns
`BACKPRESSURE` with `peer_code=PREDICTION_STALL`; confirm or repair, then retry
`finish_host()` on the same publication. SDK acceptance does not prove remote delivery.

The SDK broadcasts these bytes to other players as well as spectators. The player
relay adapter rejects FRGS envelopes before changing its protocol clocks or player
confirmation. Use a separate stream lifetime and private key for each admitted
viewer; this bridge does not multiplex viewers or provide late state transfer.
Room or connection replacement, changed player identity, source reconfiguration
and detach stop publication. Setup observes lifetime signals before protocol conversion
or SDK getters, and releases temporary listeners on every exit. A signal during a
getter permanently rejects that publication with `WRONG_STATE`, even when room and
player values stay unchanged. Polling, acceptance and finalization cannot revive it.
The admitted viewer's `spectator_disconnected` notification also stops publication;
another viewer's departure leaves it running. Setup observes these selected-participant
notifications too, and retained old callbacks cannot stop a replacement lifetime.
Detach and explicitly configure a fresh publication to recover. Rejected setup and
`detach()` leave player gameplay running.

Deterministic SDK doubles cover canonical playback through ring reuse, bounded
pressure, explicit receipt, clean end and shared player traffic. The native witness
adds actual SDK/server publication, receipt and authenticated control delivery.
Exported Fortress games and the complete lifecycle matrix remain unqualified in #131;
this API does not extend the browser support claim.

The scripted SDK case `corrected_drop_history` crosses both production adapters
with a status-sensitive game. The host repairs a predicted tail after freezing a
departed slot, then continues while the SDK refuses publication. The exact signed
row survives eviction from the host's input ring. A delayed viewer resumes through
seven independently calculated canonical boundaries, preserving finalized statuses
and seated confirmation, then consumes the complete clean tail. An executed
control that changes disconnected statuses to confirmed statuses fails the canonical
and exported-status checks while preserving input bytes. This case uses SDK
doubles; it does not establish socket, server or exported-browser drop acceptance.

## Check playback against the pinned spectator model

`make spectator-model` records actual production viewer rings, input tags, host
frontiers, backlog, catch-up classification, public pacing advice and completed
playback boundaries twice. Callback transcripts must match the original input log.
CI runs the gate on both engine pins.

The gate executes the actual pinned Rust host and spectator sessions through a
fake socket and their real synchronization messages. Eight workloads cross ring
capacities two and three, catch-up speeds one and two, and either fill the ring
before playback or play frame zero first. Each workload compares every delivery
boundary, backlog, service cycle and exact twelve-row callback transcript with
Godot, twice. Rust's public backlog and current-frame getters supply observations;
its actual returned ADVANCE request count proves the selected catch-up decision.
Rust has no public pacing-advice getter, so its advice field is derived from the
observed backlog and configured policy, then checked against the request count.

Eight additional source workloads use capacities four and five, delay one or
capacity minus one, and catch-up speeds one and two. Every delivery boundary,
service cycle and callback input must agree with the pinned Rust session.
These runs exercise the strict catch-up threshold and repeated ring reuse while
leaving the delayed final rows buffered. They do not simulate a clean host ending.
Controls reject bypassed delay, catch-up based on the raw backlog, and reordered
callback inputs. An executed control swaps the first two delivered input samples;
it preserves their total but must fail the original ordered transcript comparison.

Another 56 source workloads exercise every roster size from two through eight
with a different changing byte stream in every slot. Capacities four and five,
delays one and capacity minus one, and catch-up speeds one and two cross repeated
ring reuse. Every received row, individual Godot request, complete service cycle
and ordered callback row is checked against independently generated original inputs;
the service observations and callbacks must also match actual pinned Rust sessions,
twice. An executed player-order control swaps the last two slots before delivery,
preserves each row's sum, and must fail the original ordered callback comparison.
Missing eight-player work, corrupted last-slot input and numeric type changes are
separate rejected controls. These workloads extend confirmed-input source coverage;
they do not extend the binary two-player formal projection.

A separate 280-workload comparison reserves each slot position in turn in the pinned
Rust host. Each trace names its reserved slot; every roster keeps the original last-slot controls. The actual source builder freezes that slot at its default input zero
and supplies `Disconnected` status from frame zero. Other slots keep their changing
original inputs. Godot receives those same complete finalized rows. Every callback
records each input and status plus an independently reconstructed, status-sensitive
canonical state. The same roster, ring, delay, catch-up and repeatability matrix applies.

This source profile enables the upstream `hot-join` feature and uses prediction
window one on both source handshake endpoints, as required for reserved slots.
The viewer still consumes only finalized rows. The source host's initial publication
waits one advance, then delivers its first two rows together; that exact startup
schedule is independently checked. This is reserved-slot playback evidence, not
mid-match coordinated-drop or hot-join admission evidence.

An executed Godot control changes the disconnected status to confirmed while
preserving every input byte. Both the ordered status transcript and the first
canonical state must disagree with the source. Separate controls reject a changed
frozen input, changed canonical boundary, omitted slot workloads and malformed numeric status types.
An executed shifted-status control moves `Disconnected` to the adjacent slot while
preserving input bytes and each row's status sum; exact per-slot comparison rejects it.
Another control retains the original canonical states and final state while swapping
two statuses in the first callback; the first ordered status comparison still rejects it.
These workloads do not extend the binary two-player formal projection.

The original pinned model remains unchanged. Its `ReceiveInput` action forces
`framesBehind = 0` while `currentFrame = NULL_FRAME`; actual Rust and Godot both
report backlog one after the first row. The original preplay traces must still
deadlock at exactly cursor three. Separate speed-one post-start traces continue
to check the original model after explicitly labeled synthetic setup; an illegal
advance over missing input must deadlock inside actual playback at cursor five.

A derived runtime-aligned model removes only the two reviewed NULL-current-frame
exceptions in `ComputeFramesBehind` and `ReceiveInput`. Exact source anchors fail
closed on pin drift. TLC checks every original initial/post-state through this
relation, including preplay full rings and repeated ring reuse. Synchronization
setup remains synthetic and explicitly labeled. The model uses catch-up speed one
for the port's individual request boundaries; the independent executed Rust/Godot
comparison checks complete service cycles at speeds one and two. This separates
request refinement from the source API's multi-request call boundary.

The aligned trace control hides only the first received row's startup backlog;
TLC must reject it at cursor three. Differential controls hide that same backlog
or shorten the first catch-up batch, requiring the corresponding field diagnostic.
Raw original observations, generated models, TLC logs, source/tool identities,
Rust binary hashes and all control results remain in the receipt directory.

The formal scope uses two-player binary input for one active slot, neutral input
for the other, zero delay and in-order host delivery. The separate source comparison
covers every two-to-eight-player roster, changing inputs in all slots and the delays above.
The port exposes the next
frame; Rust and the model expose the last played frame, so projection subtracts
one. Handshake/event/timeout parity, mid-match disconnected-status transitions, arbitrary delivery
and live SignalFish acceptance remain in #47 and #131. This fixes the scoped
startup relation in [#203](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/203)
without changing reviewed pins or production playback. Omit `--godot` from the
direct `scripts/oracle/spectator_launch.py` invocation to run only the upstream model.

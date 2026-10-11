# Actual P2P gameplay oracle

Run the source and Godot multiplayer gate with either pinned editor:

```sh
python3 scripts/oracle/p2p_launch.py --godot /path/to/godot --offline
```

This P3/P4 development harness executes the pinned upstream
`P2PSession` and the shipped `FortressPeerSession`. It is separate from the
sync-test oracle and the P2 handshake oracle. Rust remains a development tool;
the addon has no native extension or Rust dependency.

## Source-only profile audits

The default Rust, Python and Godot comparison profile accepts prediction windows
2 through 8. Windows zero and one are rejected by both default executables.
For development audits of upstream low-window behavior, the Rust source adapter
has an explicit mode:

```sh
.cache/reference/target/debug/p2p --profile-audit < low-window-scenario.json
```

This mode accepts windows zero through eight and executes the same actual
upstream sessions. It does not enable Python/Godot comparison for unsupported
profiles or produce a multiplayer comparison receipt. Its raw output preserves
the original low-window scenario. The normal gate checks default rejection of
zero/one and runs each explicit low-window audit twice in fresh processes.

## Actual session boundary

Every peer is an actual upstream session with one local slot and remote slots
for the other peers. The fake socket retains real `Message` values and their
attributed sender/destination. Initialization exchanges actual handshake messages
until every session reports Running. Godot independently exchanges encoded
production handshake packets. Neither side receives a forged running-state
flag, callback plan, predicted input or confirmation result.

The submitted scheduler contains `step(peer, now_us, bytes)`,
`poll(peer, now_us)` and `deliver(observed_packet_id, now_us)` operations.
Schedules are generated from observed outgoing packet inventories. Input samples
are submitted explicitly; observed requests never choose Godot game callbacks.

A source delivery queues a real message, then calls `poll_remote_clients()`.
That API both receives messages and services endpoint timers. Its Godot boundary
is `receive_and_poll(packet, attributed_sender, now_us)`. Retry gossip uses the
receipt bank from before delivery, as upstream polls endpoint timers before
handling their input events in the session. Input retention precedes ACK
publication; every timer service and outgoing packet remains observed. Step invokes source
`add_local_input`/`advance_frame` and Godot's production Driver facade.

The injected clock starts at zero and advances only through submitted integer
microseconds. Each upstream peer has an explicit protocol RNG seed. A clock
origin supplies the upstream Instant representation; real elapsed time does not
choose a delivery or simulation frame. The original P3 scenarios explicitly disable Godot lifecycle controls and set
source quality and keepalive intervals outside their schedules. Optional
`lifecycle` settings enable actual P4 timers and source `DesyncDetection`.
They specify quality, keepalive, notify and timeout intervals in integer
microseconds, a checksum interval in frames, and an optional divergent peer.
The divergent peer starts with one changed accumulator byte in both applications.
Hot join and graceful membership changes remain outside this gate.

## Compared observations

Every operation preserves its addressed peer, current frame before and after,
actual `confirmed_frame`, ordered save/load/advance callbacks, all input bytes
and confirmed/predicted statuses, canonical application bytes, 16-byte checksum,
application events and outgoing packet IDs. Every outgoing gameplay packet
retains its sender/destination and semantic input or ACK fields: start frame,
ACK frame, player slot, exact frame bytes, and every connection-status slot,
including epoch and disconnected flags.

The source retains raw serde messages as well. Semantic decompression calls the
actual upstream `network::compression::decode_with_max_len`; it uses previously
observed frame bytes as the delta reference. The first delayed packet uses the
upstream zero initial reference. A second source-process validation re-decodes
every raw compressed packet and requires exact semantic agreement. The Godot
side decodes actual production codec bytes. Compression bytes and packet header
layout differ intentionally between Rust and Godot; exact gameplay semantics
remain compared.

Two narrow API differences are explicit. Upstream's first advance emits two
identical initial saves; comparison removes exactly one adjacent identical
initial save at frame zero. All other saves remain ordered and compared,
including the save at a stalled prediction boundary. Upstream reports a stalled
step as successful with an unchanged frame, while the Godot Driver reports
`PREDICTION_STALL`; only the source observation maps successful unchanged
steps to that error. Godot must report the explicit stall code; null or the
source error spelling on the Godot side fails comparison. Both exceptions apply
only to source observations.

Upstream emits no application event for ordinary input arrival. Godot's
`inputs_received` extension events are retained in a separate inventory with
strict field/type validation. Unknown extension events fail the gate. They do
not count as upstream event parity; endpoint tests own their emission contract.

## Coverage and negative controls

The original gameplay corpus has 26 scenarios: every mesh size 2 through 8, each with delay zero
and delay two; and loss, reorder/duplicate, prediction stall/recovery and retry
cases for 2, 4 and 8 peers. Loss drops the first input and ACK flight. Retry
checks exactly 200000 microseconds versus 200001, then drops ACKs and checks the
next exact interval and interval-plus-one. Duplicate packets do not manufacture
new input progress. Full meshes use the upstream gossip minimum for confirmation;
voluntary idle confirmation can lag the last locally received frame until another
input packet carries updated gossip. Exhausted-window recovery is separately
covered by `tests/unit/test_stalled_gossip.gd`: drained three/eight-peer meshes,
dropped/reordered status carriers, repeated ACK drainage, unchanged stalled samples
and missing actual input. The automatic session predicate follows pinned
`p2p_session.rs::gossip_holds_confirmation_below_receipts`; the endpoint repeats
one acknowledged input under the strict `protocol/mod.rs` nudge gates. This is a
source audit plus production Godot regression, not a separately executed Rust
reproduction of that schedule. The original differential corpus does not claim
voluntary idle convergence or disconnect-agreement nudge parity.

The callback game is the existing stateful reference game: accumulators,
seeded RNG and pending events are saved and restored. Validation reconstructs
its canonical callback states and independently checks each confirmed input
against the original submitted input history, including the delayed neutral
prefix. A temporal mutation swaps the first two confirmed samples, recomputes
consistent callback states and checksums, and preserves every final peer state.
It must still fail at operation zero's confirmed prefix.

Both programs run twice in fresh processes. Standalone scenario validation
rejects empty work, unknown fields, wrong input widths and malformed numeric
values. Python validates embedded scenarios and every nested trace field before
comparison, rejecting boolean/float aliases. Godot also scans original JSON
numeric tokens before parsing and canonicalization, rejecting decimal and
exponent notation while preserving quoted strings and escapes. Real subprocess
controls cover float and null numeric fields through both standalone programs,
malformed Rust/Godot input, omitted completion records, unknown events, altered
confirmation, plausible JSON followed by nonzero exit, and corrupted compressed
bytes through the actual upstream decoder. Controls require their intended
diagnostic and exit code rather than accepting unrelated engine parse errors.


## Lifecycle observations

Eight additional two-peer scenarios compare real quality reports, echoed replies,
keepalives, interruption and resume events, timeout, pacing recommendations,
and checksum exchange. Timer cases exercise interval equality and interval plus
one. Delayed quality replies produce actual RTT observations. One case combines
100 ms RTT with retained input to compare the source frame estimate at 60 FPS.
The skew case produces an actual `WaitRecommendation`, including its skip count.
Matching and reordered input cases exchange nonzero checksum inventories without
false desync events. The divergent initial state produces an actual source
`DesyncDetected` with frame, peer and both checksums.

Source observations call public `network_stats()` and `frames_ahead()`.
`network_stats()` returns `NotSynchronized` before one whole elapsed second.
Traces retain that error instead of substituting inferred zero gauges.
Available RTT and local/remote frame advantage gauges remain compared.
Godot observations preserve the source API's subsecond availability rule;
Godot's own gauges are available earlier through its production API.
The source caches pacing before submitting the next local input.
Checksum send and comparison use confirmation published by the previous advance,
not a receipt floor that increased during delivery. Comparisons require a frame
strictly below that published floor. Actual callback snapshots supply checksums.

Raw source messages retain unsigned 128-bit checksum and timestamp integers.
The development Rust adapter enables JSON arbitrary precision to preserve them.
Python validates each raw integer independently before semantic comparison.
Positive raw-message probes require exact ping/pong values above 64 bits,
including the maximum unsigned-128 value, through the actual source decoder.
Separate rejection controls cover boolean, float, string, null and range aliases.
Godot decodes actual production bytes, including tokens and checksum payloads.
Standalone malformed nested settings, including a present null lifecycle object,
fail in both real executables. Omission retains the P3 profile.
Persistent controls alter events, peer/frame/checksum payloads, metrics and
terminal boundaries. Each control declares its intended diagnostic and selected
operation or packet before execution. The unfrozen terminal control preserves
valid canonical callback/state evidence so rejection must reach the frozen-policy
guard. The eight named acceptance cases require nonzero actual source
observations and their specified controls before publishing success; arbitrary
short custom profiles remain valid inputs. Receipts retain these counts.
The standalone `--corpus-case` option requires a recognized name, an expected
source trace and a lifecycle-enabled scenario. Omit it for custom input profiles.
Additional observer controls encode mutated ping, pong and
checksum bytes, decode them, and require rejection at the selected packet.

Godot fixed membership terminates on a timeout or detected desync.
The source can continue callbacks and input submission after reporting desync.
A narrow comparison projection permits only the first terminal event at the
final submitted operation. It requires the exact trigger payload, peer and
pre-operation canonical state. Godot must preserve that frame and state without
callbacks. Raw source callbacks, subsequent state and outgoing input remain in
the artifact; the comparison excludes only this final source continuation.
Godot's terminal `GOODBYE` packets use reason 255. Their exact encoded observations
and local link-close extension events remain recorded. Only the final real desync
policy permits them: exactly three consecutive GOODBYEs for each owned remote,
and exactly one ordered close event per remote. Self events, duplicates, missing
notifications and timeout notifications fail validation. The projection excludes
only that validated final terminal suffix. Postterminal gauges remain raw observations,
with no cross-policy parity claim. Extra earlier triggers or later submitted
operations invalidate the projection. Runtime tests separately verify frozen
postterminal API calls and bounded terminal notification.

The comparison profile remains prediction windows 2 through 8. A source-only
zero-window checksum audit advances without SAVE requests or checksum reports.
Godot captures additional zero-window SAVE callbacks to provide usable checksums;
that stronger runtime behavior is an explicit extension outside this comparison.
Unknown or stale pong hardening, hostile peer policies, bounded diagnostic
ownership and full release matrices have separate runtime coverage.

## Evidence

The output directory retains submitted scenarios, raw source observations,
Godot observations, each repeat's process logs, control artifacts and a receipt.
The receipt records source/tool/manifest/engine/binary hashes, upstream revision,
verified archive identity, upstream Rust tree/manifest/lock hashes, Cargo and
Rust versions, Git commit/dirty state and ordered case inventories. Source
inventory or content changes during execution invalidate the attempt. The
upstream inventory includes every Rust file plus its manifest and lock; it is
checked after compilation and before publication. Engine identity is captured
before its version probe, and Rust binary identity immediately after compilation;
paths, bytes and executable modes are rechecked before execution and publication.
Receipts retain these captured identities rather than hashing replacement tools
after they have executed. Isolated drift controls never modify trusted caches. A prior
success receipt is removed before any replacement execution, including a failed
engine probe.

This gate proves the scoped fake-transport gameplay path. It does not establish
WebRTC delivery, browser deployment, cross-platform release parity, spectator
sessions, replay format, hot join or broad release timing/fault coverage.

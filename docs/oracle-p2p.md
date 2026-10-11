# Actual P2P gameplay oracle

Run the source and Godot multiplayer gate with either pinned editor:

```sh
python3 scripts/oracle/p2p_launch.py --godot /path/to/godot --offline
```

This P3 development harness executes the pinned upstream
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
choose a delivery or simulation frame. Quality reports and keepalives are set
outside these schedules. Disconnect, checksum exchange, hot join and graceful
closure are outside this gate.

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

The corpus has 26 scenarios: every mesh size 2 through 8, each with delay zero
and delay two; and loss, reorder/duplicate, prediction stall/recovery and retry
cases for 2, 4 and 8 peers. Loss drops the first input and ACK flight. Retry
checks exactly 200000 microseconds versus 200001, then drops ACKs and checks the
next exact interval and interval-plus-one. Duplicate packets do not manufacture
new input progress. Full meshes use the upstream gossip minimum for confirmation;
idle confirmation can lag the last locally received frame until another input
packet carries updated gossip. This gate does not claim idle mesh convergence.

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
sessions, disconnect policy, replay format, time synchronization or hot join.

# Peer timing, checksums and terminal events

`FortressPeerSession` enables lifecycle controls by default. Pass an optional
sixth `FortressLifecycleTypes.Options` argument to `configure` to select bounds
and intervals. Set `enabled = false` for an input-only session. All peers must
agree on the negotiated profile, including FPS and checksum interval.

Applications inject nonnegative, nondecreasing integer microseconds. Simulation
uses frame numbers and input bytes. Protocol timers never read a system clock.
Running `step` services timers before submitting inputs; continue calling `poll`
and draining packets, events and transitions while simulation stalls.

## Timing and interruption

| Default | Behavior |
| --- | --- |
| Quality report every 200000 microseconds | Exchange a full timestamp token and integer frame advantage. |
| Keepalive after 200000 microseconds without sends | Keep an idle link observable. Input and control sends postpone it. |
| Notify after 500000 microseconds without accepted traffic | Publish `network_interrupted` with remaining timeout milliseconds. |
| Timeout after 2000000 microseconds without accepted traffic | Publish `disconnected` and halt the fixed-membership session. |

Timers fire strictly after their interval. Accepted traffic from the negotiated
connection refreshes liveness. Wrong-source, wrong-era and malformed packets
cannot refresh it. Traffic after an interruption publishes `network_resumed`.
A terminated session cannot resume; create a new session and synchronize again.

`network_status().peers` reports integer `round_trip_time_ms`, local and remote
frame advantage, averaged frame advantage and interruption state. RTT updates
only for a retained matching quality token. Lost replies expire from a bounded
pending inventory. `network_status().frames_ahead` reports the largest peer
recommendation. A `wait_recommendation` event carries `skip_frames`; applications
choose how to pace local frame submission. The library does not sleep.

## Game checksums

The profile's `desync_interval` selects saved frame boundaries; zero disables
exchange. Reports contain the game's complete 16-byte checksum, frame number and
negotiated connection identity. They never substitute a transport or packet hash.
The game must checksum its complete deterministic state in `save_state`.

Only completed, confirmed snapshot boundaries are eligible. A pending rollback
hides affected saved states until the driver repairs them; earlier unaffected
states remain eligible. `confirmed_checksums(include_boundary = false)` exposes
owned frame, generation and checksum metadata without copying snapshot payloads.
Sending uses the last completed advance's confirmation boundary. Comparison uses
strictly earlier confirmed boundaries, matching the source's save/input ordering.

Enabled peer checksum exchange also captures saved boundaries in lockstep
(prediction window zero). The core's optional `capture_confirmed_snapshots`
configuration defaults to false; the peer façade enables it for checksum exchange.
The pinned source emits no SAVE callbacks or checksum reports in this profile.
This additional Godot capture is a tested product extension, outside callback
parity for the prediction-window-2–8 source corpus.

A mismatch publishes `desync_detected` with an owned remote `peer`, `frame`,
`local_checksum` and `remote_checksum`. It halts advancement and attempts
redundant goodbye packets to the remaining links. Invalid, conflicting,
unreasonably future or overflowing checksum reports also halt explicitly.
Stale reports outside retained comparison history are ignored.

`network_status().checksums.verified_reports` contains a bounded counter per
remote peer. It counts retained reports actually compared with equal local
checksums, so applications can distinguish verification from transmission.

## Closure and bounds

A successful local close stores `TERMINATED`. Remote loss and genuine event
publication failure store `PROTOCOL_FAILED`. A `step` that encounters a
terminal control failure returns its committed reason. Later calls return
`TERMINATED`; healthy transport pressure remains retryable.

`close(now_us, reason = 0)` accepts a byte reason, queues three best-effort
GOODBYE packets per link and halts the local game. Receiving GOODBYE halts the
fixed-membership game. Queue pressure can prevent transmission; the local
terminal outcome and diagnostic remain observable.

Lifecycle options bound pending quality tokens, averaging samples, retained
checksum frames per peer and session events. Input options separately bound
endpoint events, packets and transitions. Drain all publication queues each
service iteration. Event overflow preserves a reserved `event_capacity_exceeded`
fatal diagnostic and halts advancement; it does not silently discard a failure.
Returned byte arrays belong to the caller.

This terminal policy differs deliberately from the pinned source's callback and
continued drop-player behavior. Membership repair and continued play after a
peer leaves require a separate policy. See [source observations](oracle-p2p.md)
for the comparison boundary and [the example](peer-example.md) for visible faults.

## Downloadable observations

`peer.diagnostics()` returns a fresh JSON-compatible dictionary with schema
`fortress-peer-diagnostics-v1`. It includes current/confirmed frames, lifecycle,
terminal reason, pending correction, the shared engine's
[completed work statistics](session.md#completed-work-statistics), per-link retained
input backlog, RTT and pacing. Links use stable indices in `peer_ids()` order;
the report contains no transport identities or handshake tokens.

A terminal diagnostic retains its cause and both checksum hex strings on a real
desync. Event drains do not erase that diagnostic, and modifying a returned report
cannot change it. Reports omit SDK configuration, room codes, player names/UUIDs,
connection identities, game state and input payloads. Failed agreement reports
identify the incompatible field without exporting either value.

The online example's **Diagnostics** button downloads `fortress-diagnostics.json`
in browsers and copies JSON to the clipboard natively. It adds engine version,
active relay count and retained transport queue counts. It requires neither
`user://` persistence nor browser storage. Share the file alongside the visible
failure and reproduction steps. Export before choosing **Leave / new room**,
which replaces the application match and its diagnostics.

This report is a bounded observation snapshot. It does not contain a replay or a
canonical state/input trace. Capturing a bounded first-divergence replay window,
seed and application versions remains tracked in issue #42. The game owns those
payloads; a checksum pair alone cannot reconstruct them.

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

An `input_delay_recommendation` event suggests a higher local input delay from the
largest peer RTT. It carries `player`, `current_delay`, `suggested_delay` and
`round_trip_time_ms`. The [integration guide](integration.md#suggested-input-delay)
explains when it fires and how to apply it.

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

The default policy ends the match when a peer stops answering: the session
reports `PROTOCOL_FAILED` and every peer stops. The optional
`disconnect_behavior = CONTINUE` lifecycle policy instead freezes the departed
player's slot at the frame the mesh had confirmed, and the survivors keep
playing. The frozen slot repeats the value confirmed at that frame, reports a
`DISCONNECTED` input status and no longer holds the confirmed frontier back.
Confirmed history before that frame never changes; the frames after it are
resimulated with the frozen value. A departure before the mesh confirmed any
frame ends the match, because there is no agreed value to freeze. Every peer of
a mesh must use the same policy. Each survivor detects the departure on its
own and freezes the slot at its own confirmed frontier, so the survivors agree
only while those frontiers agree; the mesh checksum comparison reports a
disagreement as a desync. This is the graceful drop of the pinned source, not
its coordinated drop barrier: the agreed frame is the mesh-confirmed frontier
rather than an all-survivor certificate, so a coordinated drop remains open
work. See
[source observations](oracle-p2p.md) for the comparison boundary and
[the example](peer-example.md) for visible faults.

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
connection identities, game state and input payloads by default. Failed agreement reports
identify the incompatible field without exporting either value.

The online example's **Diagnostics** button downloads `fortress-diagnostics.json`
in browsers and copies JSON to the clipboard natively. It adds engine version,
active relay count and retained transport queue counts. It requires neither
`user://` persistence nor browser storage. Share the file alongside the visible
failure and reproduction steps. Export before **Leave / new room** to retain current transport queue counts.
The next connection creates a fresh application match and resets its diagnostics.

## Opt-in canonical divergence evidence

Set `Config.diagnostic_trace_frames` before `configure` to retain a local canonical
window (1–128 frame boundaries; default zero). The peer report then includes
`trace` with schema `fortress-canonical-trace-v1`. The expert session exposes the
same window through `diagnostic_trace()`. Disabled sessions retain no trace
payloads and preserve the default diagnostic report shape and game callbacks.

Each sorted frame contains hex-encoded canonical `SAVE` bytes and its checksum,
plus successful `ADVANCE` input bytes and prediction/confirmation status for every
player. State at frame F precedes input F. `state_available` distinguishes an
empty saved state from a frame without a SAVE callback. Tracing adds no game
callbacks; profiles without SAVE callbacks can therefore contain only inputs.
Rollback removes invalidated later states and replaces replayed inputs with their
corrected values. The window follows the simulation back to the restored frame, so
a rollback that rewinds past the window still records the frames that follow it
instead of losing the divergence region. Failed callbacks never claim completed
input application.

The first detected peer mismatch freezes the window with its frame, peer index,
both checksum domains and `source = "peer_checksum"`. A local sync-test canonical
snapshot mismatch also freezes it, with `source = "sync_test_snapshot"` and peer
index -1; its remote checksum field is the original local comparison checksum.
Canonical mismatch detection can catch equal checksums. This local evidence
survives termination, event saturation and event drains, and every report belongs
to its caller. It is not an exchanged remote snapshot or a complete replay file.
The first reported mismatch need not be the earliest divergent simulation tick.

Choose history long enough for the checksum interval and delivery delay. When
the mismatch boundary has already left the window, `snapshot_available = false`
explicitly identifies the missing evidence. A late mismatch never expands history.
The exact canonical payload ceiling is
`frames * (max_snapshot_bytes + 16 + player_count * input_width)` bytes, exposed as
`max_payload_bytes`; `retained_payload_bytes` reports actual ownership. The explicit
session storage budget also reserves bounded record metadata and application
metadata. This is a payload reservation, not an engine heap-size guarantee.
Compact trace JSON is bounded by `max_export_bytes` (hex doubles payload bytes, with
bounded metadata and JSON escaping overhead); pretty-printing adds whitespace.

Applications may set `diagnostic_seed` and `diagnostic_version` (128 UTF-8 bytes
each), and `diagnostic_replay_command` (512 UTF-8 bytes). Seeds are strings to
preserve wide integer values. The command is descriptive text and is never run.
Leave it empty when the application has no exact replay command. The library
cannot infer application versions, seeds or how to restore an application's state.

Opt-in exports intentionally disclose the game's saved bytes, input bytes and
these application-supplied metadata strings. Review their content before sharing;
they can themselves contain sensitive data. The library automatically excludes
SDK configuration, room/player identities, connection IDs and handshake tokens.
The online example offers an explicit checkbox before Ready and defaults to disabled.
Its 120-frame local capture includes the integer game's seed and version.
Use the [offline diagnostic player](diagnostic-reproduction.md) to restore a captured
window and locate the first different canonical state in another game build.
The complete cross-platform diagnostic workflow remains tracked in issue #42.

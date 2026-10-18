# Changelog

## [Unreleased]

### Added

- Add a diagnostic file viewer for online captures. Open JSON locally, inspect retained boundaries and metadata, then play or step through canonical comparisons. Playback identifies the first differing saved state.

- Add a replay viewer for online recordings. Open a downloaded file without a server, then play, pause, step, restart or go to a chosen frame. Playback validates recorded checksums and stops at the first mismatch.

- Add offline canonical diagnostic playback and an online trace reproduction command. Restore a captured window, apply its recorded inputs, and locate the first differing saved state.

- Add optional replay recording to the online example. Select Record replay before Ready, then Download replay to save the first ten minutes of confirmed inputs. Diagnostic capture remains a separate choice.

- Add an `input_delay_recommendation` peer event that suggests a higher input delay from measured round-trip time. Your game chooses whether to apply it. Press R in the online example to apply a suggestion.

- Add `set_input_delay` so a player can raise input delay mid-match. Replays record the change. Press = in the online example to try it.

- Add match recording and playback. Set `replay_max_frames` to record confirmed inputs with engine, addon, seed and session details, then play the bytes with `FortressReplayPlayer`. Playback checks recorded state checksums and stops at the first frame that differs.

- Add peer completion notifications after game callbacks and network controls. Reentrant peer mutations remain blocked until handlers return.

- Add an online checkbox to include bounded game state and inputs in diagnostic downloads. Choose before Ready; capture stays off by default.

- Add opt-in canonical desync traces with bounded state/input history and application metadata. Traces freeze at the first detected mismatch and survive event drains; game payloads remain private by default.

- Add a typed driver completion signal for presentation updates after rollback, stalls and callback failures. Recursive driver calls stay blocked until signal handlers return.

- Add owned rollback, replay-work and stall statistics. The online Diagnostics button excludes room IDs and tokens; game payloads require explicit opt-in. Terminal causes survive event drains.

- Add a playable shots example with adjustable remote-input delay. Move and fire to see prediction, rollback and stalls; confirmed effect pulses play once. Run `examples/integration/integration.tscn` without a server or native extension.

- Add an integration guide and example for your own game: inputs, complete snapshots, the frame loop, stalls and errors. Its effects ledger plays sounds only for confirmed frames, so a shot predicted from late input never plays by mistake.

- Add a playable two-player online example with SignalFish rooms, WebRTC and relay fallback. Install the optional SDK, create or join a room, then ready up and start. Leave and create a fresh room to restart.

- Add per-peer SignalFish relay fallback and direct restoration in one rollback session. Configure the fallback coordinator with both adapters; confirmed history survives overlapping delivery.

- Add bounded SignalFish WebRTC byte delivery with unordered input transport, owned retry queues and sender checks. Reserve mesh packet reads for the adapter and restart after plan replacement.

- Add bounded SignalFish binary relay with recipient envelopes, owned retry queues and send backpressure. Applications retain refused batches and restart after receive overflow or reconnect.

- Add optional SignalFish membership setup with stable UUID slots, handshake agreement, sender checks and v3 plan selection. Reconnect recovery remains planned.

- Add peer RTT, pacing hints, interruption and resume events, and confirmed game checksums. Fixed-membership sessions halt on timeout, closure or desync; create a new session to restart.

- Add fixed-membership byte sessions for 2–8 player slots with retained input retries, cumulative ACKs and mesh confirmation. Applications supply delivery and drain bounded outputs.

- Add a playable two-peer packet-loss example with prediction stalls and recovery.

- Add bounded peer handshakes with explicit configuration mismatch events, injected time and tokens, retries, and synchronization progress.

- Add a playable offline sync-test example with complete integer snapshots and rollback-safe presentation.

- Add complete snapshot-read checks so callbacks can reject trailing bytes before restoring game state.

- Add bounded versioned protocol messages for handshake, inputs, acknowledgements, timing and checksums.

- Add local sync-test sessions, bounded snapshot history, ordered rollback requests, and a synchronous game driver.

- Add a bounded raw input queue with owned bytes, frame delay, and repeat-last prediction.

### Fixed

- Fix stale WebRTC callbacks after connection closure. Create a fresh connection wrapper before initializing a replacement.

- Fix replay validation accepting failed snapshot writes when the callback returned a matching checksum. Playback now stops with `SNAPSHOT_FAILED` at the affected frame.

- Fix a match stalling after a long input backlog when peers used different handshake `max_packet_bytes` values. Peers now share their limits while connecting, and each sends batches that fit the smaller one.

- Fix a match stalling when one peer used a larger `max_input_frames` than another. Each peer now accepts batches up to the protocol limit of 128 frames, and the option only limits what it sends.

- Fix a match ending with `PROTOCOL_FAILED` when peers used different `queue_capacity` values and one raised input delay. Peers now compare capacities while connecting and refuse to start. **Behavior change:** the wire layout is now version 2, so older builds cannot join. Set `queue_capacity` on the handshake profile when you change it from 128.

- Fix peer sessions ending with `PROTOCOL_FAILED` when a large `input_delay` overflowed the other peer's input queue. **Behavior change:** `configure` now returns `INVALID_ARGUMENT` for a starting delay above `FortressPeerSession.max_input_delay(config)`.

- Fix SignalFish plan callbacks reviving ended adapters or recursively detaching meshes. Replacement attachment waits until teardown returns.

- Fix Firefox WebRTC connections failing when SignalFish omits ICE media IDs. The connection factory resolves missing IDs from the remote SDP while preserving explicit IDs.

- Fix stale packets and SDK callbacks ending restarted online games. Foreign packet identities cannot change gameplay or liveness, and callbacks from an old connection cannot change a later room.

- Fix online failures leaving signaling connections open. Failed games close their connections and keep movement stopped; use Leave / new room to join a fresh match.

- Fix peer timeouts delayed by another peer's full outgoing queue. Recoverable send pressure no longer prevents polling other links.

- Fix online expiry checks while outgoing batches are refused. On resume, overdue matches stop before buffered traffic or movement; leave and create a fresh room. Handshake timeouts remain observable under retry pressure.

- Fix online sessions ending when gameplay packets overtake the final handshake reply. Valid early packets are discarded until synchronization completes, and the sender retries its original inputs.

- Fix SignalFish teardown errors after Godot removes a failed WebRTC peer. Install `FortressSignalFishWebRTCMultiplayerPeer.create` as the mesh's `multiplayer_peer_factory` before its first plan.

- Fix stalled meshes after pending inputs drain by repeating bounded receipt gossip. Keep stalled samples unchanged and confirmation bound to actual inputs.

- Fix invalid transport token callbacks retaining oversized data. Relay and WebRTC adapters validate null or exactly 16 bytes before copying.

### Changed

- **Breaking**: Change exact endpoint byte budgets to reserve one extra local input frame for acknowledged-input recovery.

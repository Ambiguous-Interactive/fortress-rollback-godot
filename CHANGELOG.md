# Changelog

## [Unreleased]

### Added

- Agree the frozen frame when a player leaves. With `disconnect_behavior = CONTINUE` and more than one survivor left, the survivors exchange their freezable frame windows and freeze the departed slot at one common frame, so they keep the same confirmed history instead of splitting at their own frontiers. The match holds while the survivors agree, the agreement is bounded by `drop_barrier_timeout_us`, and a barrier that cannot agree reports `peer_drop_unconfirmed` and falls back to the survivor's own frontier.

- Negotiate the spectator envelope before the first row. The host offers the envelope version and the optional kinds it can publish, the viewer answers with the version it can speak, and the two sides refuse each other at startup with one recorded reason when they cannot agree. A viewer that only speaks version 1 now fails before it plays anything, and a host without an agreement publishes no row.

- Authenticate the spectator byte envelope. Every packet now carries a keyed tag and the digest of the agreed match, so a viewer accepts only the host and the match it agreed with. The envelope version moves from 1 to 2.

- Keep the match running when a player leaves. Set `disconnect_behavior = CONTINUE` on the peer lifecycle options and a departed player's slot is frozen at the frame the mesh had confirmed. The survivors keep playing, the departed input repeats its last confirmed value and reports a `DISCONNECTED` status, and the confirmed history before that frame never changes. The default policy still ends the match when a peer stops answering.

- Report the progress of every test case with the time it took. The runner measures each case with an injected clock: a deterministic tick clock in the native runner, the real host clock in the exported browser host. A rejected browser run names the last completed case and the case in flight.

- Copy snapshot bytes with one native append instead of one interpreted step per byte. A game that saves 4 KiB of state per frame now spends about 3 microseconds on the write instead of about 60, and the writer no longer reserves its full capacity up front. The saved bytes, the overflow behavior and the caller-owned copy are unchanged.

- Add `driver.status()` and `driver.statistics()`. A client that only holds the driver now reads the current frame, the confirmed frame, the lifecycle and the counters.

- Add the session's terminal `reason` and `failure_frame` to every driver and peer step result. A desync or a callback failure is no longer reported as a plain stop.

- Add `replay.matches_config()` and a configuration argument to the replay player. A recording from another roster, sample width, neutral input, seed or version is refused with `INCOMPATIBLE_RECORDING`.

- Add `player.skipped_frames()`. A recording whose input was substituted is no longer mistaken for a faithful copy of the original match.

- Keep the viewer's playback policy when a spectator stream is reconfigured. A policy that no longer fits the new ring falls back to the session defaults.


- Add transport traffic reporting. `poll()` results now carry `activity`, the number of transport items taken off the wire, refused ones included, and the direct, relay and composed adapters expose `idle()`.

- Stop the online example's service batch once the transport is idle. A busy or refused route keeps the whole bounded batch, so a slow link still drains while an idle page stops spending its frame budget on repeated polls.

- Add explicit local ownership of the shared reference cache. A second local probe reports who owns the cache instead of deleting the first run's logs.

- Add `make prune`, `make prune-apply`, `make disk` and `make scratch` to keep the machine-local caches and scratch bounded. The pruner never removes a path a tracked file names, never removes a tree a running session still holds, and a dry run is the default.

- Add a scratch-copy helper at `scripts/scratch_workspace.py`. It skips `.cache/`, `.git`, `.godot` and `progress/`, so an isolated run no longer copies the whole cache with the tree.

- Add a disk budget to the devcontainer acceptance harness. `verify.sh` reports the repository cache and container scratch sizes and fails above 25 GB and 20 GB. The reading keeps the size `du` reported when part of the tree could not be read.

- Add expert replay requests through `FortressReplayPlayer.configure_expert()`. Dispatch the same ordered saves and advances used by callback playback.

- Add N-key single-frame inspection to the spectator example. It preserves viewing delay and pause, and can drain a clean final tail.

- Add `FrameInputs.player_count()` and `read_into()` for reusable fixed-width input buffers. Use `read()` when you need input status or prefer bulk copies for wide samples.

- Add typed spectator playback events for waiting, contiguous host input, clean host closure and terminal completion or failure. Driver results carry events after callbacks finish.

- Add replay checksum coverage to the viewer. Recordings without checksums clearly report that playback could not be verified.

- Add bounded final receipt gossip to explicit peer recovery. A mesh can confirm its last simulated inputs after sampling stops, including when a final gossip packet is lost.

- Add recovery without a new simulation frame through `FortressDriver.recover()` and `FortressSession.begin_recovery()`. Finalize corrected replay and spectator tails while preserving staged input.

- Add E to end the local spectator example's host. Outstanding inputs settle before the viewer drains its complete final history, including after pause and resume.

- Add one-frame backward navigation to the replay viewer, including inspection before a checksum failure. Longer restores remain bounded and can be canceled.

- Add a bounded spectator host publisher that retains refused rows and sends keepalives while delivery waits.

- Add replay playback speeds from ¼× to 4×. Frame stepping and navigation still use exact recorded frames.

- Add expected and actual checksum values to replay failures, including navigation errors. The replay viewer shows both values at the failed frame.

- Add spectator host keepalives for input stalls and paused viewers. Hosts must agree receiver support before sending the new packet kind.

- Add bounded replay checkpoints for faster repeated navigation. The replay viewer restores previously validated boundaries and checks the remaining inputs.

- Add versioned spectator byte delivery with lifetime checks, bounded reordered rows, clean endings and injected-clock host expiry. Games supply authenticated transport.

- Add confirmed-input spectator playback and a playable delayed-view example. Pause and catch up the viewer while the host continues. Live spectator networking remains planned.

- Compare sequential replay playback with actual pinned upstream sessions and independent canonical state histories on both engine pins.

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

- Fix the exported online witness failing its corrupt control at random. The corruption is applied while a peer restores a snapshot, and the control held one input for the whole round, so the repeat-the-last-actual prediction was always correct and no peer ever rolled back. The witness now holds the changed input until every peer has restored, so the deliberate corruption always lands, and the corrupted peer must terminate with the desync reason while the healthy peer keeps its confirmed history.

- Fix the canonical diagnostic trace losing the divergence region after a rollback. The window follows the simulation back to the restored frame, so the frames that follow a rollback are recorded instead of rejected, and the restored boundary keeps its canonical state so the re-opened window stays restorable.

- Fix spectator playback simulating a stale host row. A missing retained row now ends the advance with `HISTORY_UNAVAILABLE` and no game callback.

- Fix one source of truth for the roster and sample-width limits. The configuration and the spectator byte envelope share the same bounds.

- Fix the spectator guide claiming 72 model schedules. The model runs 120.

- Fix the integration guide promising a sound per shot and advising a bare reconfiguration. The example calls a game hook, and a restart needs a new game object.

- Fix the oracle launchers so the documented `make` commands find a Godot engine installed on `PATH`. The engine is resolved before the Rust toolchain is installed, and the receipt names the executable that ran.

- Apply one engine-resolution rule to every probe and launcher. A name on `PATH`, a relative path and an absolute path now resolve the same way, and a name that names nothing fails with a readable message.

- Keep the browser error inventory when the ownership watchdog rejects a run, and record each ownership round as it starts, so a timeout names the round that was running.


- Fix driver input submission hiding terminal frame or batch exhaustion. Exhausted calls terminate before retaining new samples.

- Fix replay Step and Pause accepting an unchecked displayed boundary. Both actions now report checksum failures immediately and preserve the failed input for inspection.

- Fix spectator stream packets and timeouts affecting a viewer after direct session reconfiguration. Reconfigure the stream with a fresh connection identity to resume delivery.

- Fix incompatible reflected snapshot and input callback types being accepted during setup. Rejected replacements preserve the active game; erased engine metadata cannot identify every mismatch.

- Fix incompatible built-in game callback parameter types being accepted during setup. Invalid replacements leave the active game intact.

- Fix replay navigation bypassing bounded snapshot validation at paused frames. Callback and snapshot failures now stop playback with the selected frame.

- Fix corrected driver retries after incomplete multiplayer input lists. Missing local samples are rejected before retaining other players’ buttons.

- Fix spectator confirmation being restricted by player-only mesh controls. Played host-confirmed rows remain available for export.

- Fix invalid game callback argument counts being accepted during driver, replay and diagnostic setup. Configuration now fails early and preserves any previous playback.

- Fix corrected driver retries after malformed multi-player input lists. Invalid sample metadata is rejected before any earlier sample is retained.

- Stop matches explicitly when game callbacks return invalid values. Drivers release request views and notify peer closure instead of leaving the match stalled.

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

### Improved

- Improve wide-input queue insertion with native byte copying while preserving input, prediction and rollback-floor ownership.

- Improve driver handling of repeated identical local samples. Each player submits once after the complete list passes validation.

### Changed

- **Breaking**: Change the replay file format to version 4. Every frame now carries the digest of its own input row, so a corrupted input is refused with `DESYNC` at the frame that owns it - including a row in front of a frame that carries no state checksum. Version 1, version 2 and version 3 files are refused with `UNSUPPORTED_VERSION`. A recording now spends 16 more bytes per frame, so the largest recording a configuration can hold is smaller.

- Name the reason the replay viewer refuses a file. An older format version, a malformed file and an oversized file each get their own message.

- Build the pinned relay server into one revision-keyed shared cargo tree instead of a per-run output directory. The executable is still published at `<output>/target/debug/signal-fish-server`, so every documented path and the build receipt keep working.

- Reuse the pinned relay server's compiled dependencies across builds and across the six SignalFish CI jobs. The build now keeps its crates at one fixed Cargo home, the CI caches the dependency tree, and the server itself is still rebuilt from the pinned source every time.

- Prune stale scratch and superseded container caches on every container start, and report the repository cache without modifying it.

- **Breaking**: Change exact endpoint byte budgets to reserve one extra local input frame for acknowledged-input recovery.

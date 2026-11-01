# Changelog

## [Unreleased]

### Added

- Add native replay file drops with bounded validation and preservation of the current recording after refused imports.

- Add spectator input-buffer capacity observations and a resume/catch-up prompt when paused input fills the buffer.

- Add a draggable replay timeline with elapsed and total recorded time. Selection uses bounded, verified navigation and finishes paused.

- Add C to catch the local spectator up through currently buffered rows, preserving its viewing delay and normal catch-up rate.

- Add spectator replay progress and a warning before its recording limit. Continued viewing shows omitted frames and explains where the saved replay ends.

- Add recording progress through session, driver and peer APIs. The online example shows finalized, pending and omitted gameplay at the recording limit.

- Add spectator host observations for liveness, remaining timeout and missing final rows, including through the SignalFish viewer adapter.

- Add `DiagnosticPlayer.terminate()` to cancel captured-window playback, expire active views and preserve earlier failure evidence.

- Add spectator backlog feedback during pause and playback. Show contiguous buffered input separately from later rows waiting beyond gaps.

- Add saved spectator-example playback in the replay viewer, including checksum validation, Fire input inspection and backward navigation. New exports identify their game; older unnamed exports remain refused.

- Add comma/period spectator catch-up controls. Adjust the bounded frames-per-tick limit while preserving viewing delay and pause.

- Add Previous/Next recorded checksum replay controls. Inspect sparse verification boundaries and recorded final states through verified navigation.

- Add spectator viewing-delay controls with [ and ]. Adjust the confirmed-frame cushion without restarting or rewinding playback.

- Add spectator missing-frame and pending-input observations. Buffering feedback names the gap and later rows already received.

- Add Previous/Next input change replay controls, including confirmed or disconnected status changes, with verified navigation.

- Add owned spectator playback status separating missing input, viewing delay, final tails and completed or stopped playback.

- Add `FrameInputs.input_status(player)` to read applied player status alongside reusable input buffers without creating an owned result.

- Add failed callback names and frames to diagnostic downloads and the offline viewer.

- Add replay input inspection showing the selected frame's recorded directions and confirmed or disconnected player statuses. Corrupt input rows are identified without displaying their values.

- Add keyboard replay inspection: P plays or pauses, N/B step forward/backward, R restarts, and Esc cancels a seek. Text entry and file chooser input remain available.

- Add empty and partial peer input retries using retained local samples. Callback and expert clients can resume stalled publication without rebuilding submitted inputs.

- Add `peer.confirmed_inputs(frame)` for owned finalized input rows. Network clients can drive confirmed effects and spectator publication without enabling recording.

- Add final replay checkpoints after successful terminal-state validation. Return to the verified ending after backward inspection without replaying the tail; checkpoint memory stays bounded.

- Add spectator example replay export with V. Save viewed history and its captured final state, including clean empty matches; recording retains the first ten minutes.

- Add replay selected-state checksum status to the player API and viewer. Paused inspection distinguishes matching, unchecked and absent recorded checksums.

- Add `SnapshotReader.read_into(destination)` to reuse small fixed-width buffers without creating read-result wrappers. Wide snapshots can keep faster native `read_bytes()` copies.

- Add state-bound spectator configuration digests so startup rejects different canonical initial worlds, even with matching seeds and rules.

- Add manual peer request batches without requiring game callbacks, including recovery and final replay capture.

- Add replay final-state validation status and explicit viewer completion messages distinguishing final-state checks from historical checksum coverage.

- Add final-state replay capture to peer sessions and the online example. Press Finish replay before leaving, then download after confirmation to verify the last simulated input.

- Add explicit final replay checksum capture and FRRP v6 playback. Capture after confirmation and recovery to detect differences caused by the last input; existing v4/v5 files remain readable.

- Add owned retained-input reads to peer sessions so clients can retry stalled steps without resampling local input.

- Add replay callback failure kinds to the player, viewer and failure downloads, identifying failed SAVE, LOAD and ADVANCE callbacks.

- Add replay comparison labels to the player API, viewer and failure downloads. Input digest failures are distinct from game-state and restored-checkpoint mismatches.

- Add a bounded SignalFish spectator host publisher with exact-byte send retries and authenticated viewer acceptance. Live exported relay qualification remains pending.

- Add replay failure downloads with the recording fingerprint, comparison hashes and observed game state for diagnosis.

- Add `FortressDriver.diagnostic_trace()` to export owned opt-in canonical evidence after callback failures without retaining the expert session.

- Add failed callback kinds to driver and peer step/recovery results, preserving the first failure through later calls.

- Add retained replay checkpoint listings and Previous/Next checkpoint viewer controls for paused inspection.

- Add an L control to demonstrate spectator host-link loss, stop buffered viewing immediately, and restart with R while the host keeps playing.

- Add bounded expert replay checkpoint navigation through `begin_restore_before()`, with ordered load and save validation before selecting the restored frame.

- Add `FortressReplayPlayer.begin_validate_current_frame()` so expert clients can validate paused inputs and state without advancing playback.

- Add an optional authenticated spectator startup control callback. Refused acceptance packets retain exact bytes for retry; host agreement still requires actual delivery.

- Add `FortressDriver.terminate()` so driver-only clients can stop a session, including from game callbacks.

- Add driver access to retained local samples and input-delay controls. Standalone clients can retry stalls without resampling; networked clients must still change delay through the peer session.

- Add bounded SignalFish spectator ingress with authenticated host filtering and strict lifetime expiry. This receive-only bridge requires separate startup acceptance; live Fortress relay support remains unqualified.

- Add `FortressDriver.confirmed_inputs(frame)` and `replay()` for finalized inputs and owned match recordings without retaining the expert session.

- Add bounded donor recovery during graceful peer drop. Survivors transfer missing actual inputs before certification and preserve confirmed history. **Breaking:** upgrade all match participants together for the new handshake feature.

- Add finalized player statuses to spectator playback. Dropped matches retain `DISCONNECTED` in callbacks and confirmed exports. The authenticated envelope moves to v3; update host and viewer together. Byte-only callers keep all-confirmed defaults.

- Report an aborted test case in the engine result. A case that dies inside a nested helper no longer looks green: on the Godot 4.7.2 pin the runner sees the script error and fails the case with the aborting file, line and message. The entry belongs to the repetition that died, and an error in a suite constructor fails the case that was being prepared. Godot 4.3 cannot observe a script error in process, so its engine result keeps the engine's own verdict and the Python launcher stays the gate there. The runner prints the capability of its engine, so a release never claims an engine result that only one pin provides.

- Keep an online match alive when a rollback correction withholds a checksum. The mesh checksum scheduler treated a snapshot that a pending repair withheld as a lost history, so a normal prediction correction ended the match with `HISTORY_UNAVAILABLE` one advance before the repair could finish. The scheduler now waits for the repair and publishes the boundary after it. A snapshot that no repair will restore still ends the match, so a real loss is not hidden behind the wait.

- Publish the supported features. A new [supported features](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/blob/main/docs/supported.md) page states the supported Godot versions, browsers, player counts, transports and game-facing features, and lists the features that are deliberately not supported yet with the issue that owns each one.

- Prove the coordinated drop with two survivors in one session. Three real peer sessions now run the barrier end to end: one peer stops answering, the two survivors notice the silence, agree one frame, publish the drop and keep one confirmed history while they keep playing, and a second departure leaves one survivor that freezes the slot on its own frontier and keeps the match running.

- Certify the frozen value of a departed player. The survivors of a match now agree on one frame and one value for the departed slot: every survivor reports the frames it still holds, the survivor that proposes the cut sends the value to the survivors that already released it, and every survivor certifies that value before the departure is committed. A survivor that certifies another value ends the match with the recorded reason `conflicting_history` instead of freezing different bytes for the same frame.

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

- Fix browser replay file-read completion replacing a recording during timeline dragging or changing feedback while game work owns playback.

- Fix spectator status checks leaving buffered playback active after SDK room, identity or receive-limit changes.

- Fix native replay and diagnostic imports exceeding their checked allocation size if a file grows during import.

- Fix ambiguous spectator catch-up key labels by naming Comma and Period.

- Fix SDK callbacks reviving canceled or expired online matches. Unsafe plan or peer-directive reentry stops the old mesh before SDK consumption and requires a fresh session.

- Fix delay prompts and shortcuts outside active online or local peer gameplay. Retain match observations and recovery instructions after failure or leaving.

- Fix driver callback replacement during unfinished expert batches so the original game state stays attached.

- Fix stale spectator host deadline checks after replacing the exposed viewer.

- Fix spectator relay status attributing a replacement viewer's host activity to an earlier SDK getter call.

- Fix recording-limit warnings to include pending frames and prompt finishing before the recording fills.

- Fix diagnostic viewer controls replacing or advancing playback during game callbacks. Successful restart or import retires the previous player.

- Fix leaving an online room during SDK or game callbacks. Leave stops further gameplay and setup, and releases active SDK owners after callbacks return.

- Fix online service and replay-finish controls during callbacks or manual requests. Busy calls preserve clocks, transport, held input and the active match.

- Fix rejected driver input lists and unsupported recovery advancing the accepted session clock. Corrected calls can retry at the last accepted time.

- Fix replay viewer controls changing playback during callbacks or manual requests. Restarting or importing another replay retires the previous player.

- Fix spectator freeze validation to reject unsupported player-slot controls consistently with freeze operations.

- Fix integration controls changing input or clocks before rejecting nested calls, sample conflicts or invalid time. Keep live matches paused during replay and allow corrected sample retries.

- Fix spectator feedback showing active watching while waiting for new confirmed inputs mid-match.

- Fix spectator publication rejecting valid service times after a poll was deferred by an active host request.

- Fix replay prefix arithmetic and checksum reads trusting invalid recording dimensions. Malformed recordings remain unavailable for export.

- Fix input reads with missing or unknown status metadata. Malformed constructed views now return `INVALID_CONFIGURATION` and preserve caller buffers.

- Fix replay failure diagnostics for missing or incomplete input digests. Playback and paused inspection identify absent evidence and preserve the computed row digest.

- Fix direct socket errors being hidden by successful relay polling. Terminal SDK failures now stop the fallback coordinator; ordinary busy sends still recover through relay.

- Fix contradictory repeated peer-drop certificates being ignored. A changed frame or value digest stops the pending agreement without freezing player history.

- Fix lost peer-drop acknowledgements stopping commit recovery at the negotiation deadline. Committed survivors retry until every live survivor acknowledges.

- Fix SignalFish spectator startup rejecting real SDK protocol metadata. Host and viewer bridges read the SDK's typed version and size limits.

- Fix remote peer-drop donors stalling healthy history recovery when another survivor refuses a certificate packet.

- Fix clean spectator completion at the frame and request-token limits. Fully played host tails report completion without requesting another frame.

- Fix spectator host sends during an expert request opened by an SDK getter. Publication retains the original packet until the request finishes.

- Fix custom spectator byte transports rejecting authenticated rows after playback history expires. Obsolete rows preserve playback and cannot renew host liveness.

- Fix SignalFish transport cleanup requested from callbacks. Direct, relay and fallback queues and relay observers are released when the active poll returns.

- Fix spectator relay failures from delayed authenticated rows after playback history wraps. Obsolete rows leave playback and host expiry unchanged.

- Fix replay accessors exposing incomplete rows or indexing missing metadata. Invalid row reads return no inputs or digest while complete earlier rows stay readable.

- Fix clean spectator closure discarding accepted rows beyond a gap. Fill the missing rows and retry `finish_host()` after `PREDICTION_STALL` to play the full tail.

- Fix replay prefixes padding missing input and checksum storage. Trimming preserves incomplete data and refuses invalid exports instead of inventing recorded bytes.

- Fix spectator relay cancellation being reported as successful completion at the final playback boundary, including empty matches.

- Fix replay checkpoint eviction during backward inspection. Revisiting an older uncached boundary preserves the initial state and newest checkpoints, including a verified match ending.

- Fix spectator stop reporting after external or callback cancellation. Preserve the original cause through later host errors; `is_complete()` and the example distinguish clean playback completion from cancellation.

- Fix replay prefixes inventing missing input digest bytes. Incomplete retained rows remain unavailable for portable export and stop playback at their owning frame.

- Fix peer-drop history transfer waiting on an unrelated survivor's refused plan. Healthy survivors receive their missing original inputs while the blocked link retries.

- Fix trimmed captured replays losing an available checksum for their new final state. Prefixes without that evidence retain their existing validation limits.

- Fix spectator example messages for startup buffering, paused final tails and lost history. Paused tails explain how to resume or step; lost history explains how to restart.

- Fix spectator example service calls during active callbacks or request batches consuming time or stopping viewing. Busy controls preserve the current match.

- Fix completed spectator playback reporting a relay failure during continued polling or late packet delivery. Cancellation and playback failures remain explicit.

- Fix local multiplayer and spectator restarts leaving retained old sessions playable. Restarts refuse active callbacks or request batches.

- Fix replay configuration raising script errors for unrelated configuration objects. Invalid replacements now preserve playback.

- Fix replay completion reporting while checkpoint navigation or state revalidation is still in progress.

- Fix spectator playback continuing after SDK receive limits become too small for the agreed packets.

- Fix coordinated-drop control retries flooding healthy survivors or postponing their deadlines when another link refuses publication.

- Fix replay export accepting malformed recording storage or missing input digests. Invalid recordings now return empty bytes instead of producing broken files.

- Fix retained-history publication starving healthy survivors when several other links refuse donor chunks during coordinated peer drop.

- Fix replay navigation accepting changed state at retained checkpoints. Repeated playback now checks canonical bytes even without recorded state checksums.

- Fix spectator startup acceptance after viewer termination or during active game requests. Retry acceptance after the viewer becomes idle.

- Fix malformed replay objects replacing active playback or reaching unchecked storage reads.

- Fix spectators continuing buffered playback after their selected host leaves or reconnects. Stop publication when the admitted viewer disconnects; unrelated roster changes preserve ongoing streams.

- Fix peer completion and transport calls bypassing shared callback guards. Handler cancellation now returns the first terminal cause.

- Fix the last surviving peer discarding already received departed-player inputs. Preserve original inputs and statuses through the final receipt before freezing every departed slot.

- Fix spectator completion handlers consuming cancellation events before later handlers and callers can observe them.

- Fix spectator host publication after SDK lifetime signals during setup or identity reads. Rejected publication leaves player gameplay running.

- Fix peer advancement and recovery hiding exhausted counters behind input errors or publishing input before termination.

- Fix spectator SDK getters detaching or replacing playback during validation. Old callbacks cannot alter a replacement viewer.

- Fix completion handlers advancing or reconfiguring a shared session through another driver or the expert API. Handlers now observe the same completed frame; cancellation remains available.

- Fix late spectator retries interrupting a clean buffered final tail. Identical retained rows and control packets remain idempotent until playback ends.

- Fix repeated spectator keepalives starving queued confirmed rows when receive work is limited to one packet per poll.

- Fix pressured peer-drop history plans immediately repeating to survivors that already accepted them, preserving output capacity for missing input rows.

- Fix reordered spectator rows blocking recovery behind a full playback ring. Bounded polling retains refused packets while accepting earlier missing rows.

- Fix refused peer-drop controls waiting another retry interval after output pressure clears. Repolling can publish the original phase immediately.

- Fix graceful-drop followers certifying a supplied frozen value that conflicts with their retained actual input. Conflicting history now ends agreement before the slot freezes.

- Fix full ten-minute online replays being refused by the viewer's file-size limit.

- Fix malformed spectator startup versions creating an unusable agreement. Corrected valid answers remain accepted after malformed input.

- Fix spectator restart leaving old drivers able to play buffered inputs. Successful stream replacement now terminates its prior owned viewer.

- Fix peer drops rewriting exposed confirmed history. Survivors certify retained actual history before agreeing a raised cut. Missing history ends the match safely. The handshake requires the new drop feature; update every peer together.

- Fix disconnected player statuses in replay recordings. New version 5 files cover input bytes and statuses with each row digest; version 4 files still load with all-confirmed defaults.

- Fix replay exports exposing unconfirmed or unrepaired tails. Coordinated drops repair staged rows, including predicted disconnect semantics.

- Fix expired peer-drop barriers accepting buffered commits. A pending barrier expires at its exact deadline; an already committed drop remains acknowledged.

- Fix unfinished peer-drop barriers silently omitting a lost survivor. The match now ends with `participant_lost`; an already committed drop remains valid.

- Fix peer-drop commit retries after a lost acknowledgement. Survivors acknowledge matching duplicate commits without repeating the drop. Refuse control messages from another operation, era or coordinator.

- Fix spectator startup offers bypassing host expiry and active callback guards. Retries cannot revive an ended viewer or answer for a replaced viewer.
- Fix spectator player-freeze calls replacing confirmed host inputs. Both freeze methods now return `UNSUPPORTED` for spectators.
- Fix replay Pause, Step and seek destinations accepting corrupted input rows until playback resumed.

- Keep the match running when a mid-match input delay raise cannot be sent. A peer session that could not hand the added frames to a peer ended the match with `PROTOCOL_FAILED`. The raise is now checked before the delay changes, so a peer that cannot take the frames or a catch-up row that was already released is reported as `NETWORK_BACKPRESSURE` and the match keeps running with the old delay.

- Fail a test case that dies before its last assertion. A GDScript runtime error inside a case aborts that function, the caller resumes and still marks the case complete, so the runner reported a broken case as passed with a truncated assertion count. The launcher now merges the engine's output into one stream, attributes the abort to the case that was executing, fails that case with the suite, the aborting line and the engine message, and keeps every other case's record.

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

- Improve local-input preflight by avoiding copied retained samples during driver and peer validation. Public sample reads keep their ownership guarantees.

- Improve driver step and recovery allocation by reusing the completed request batch's status snapshot.

- Improve multi-peer input processing by reading receipt frames without copying retained packet history. Public status snapshots keep their ownership guarantees.

- Improve wide-input queue insertion with native byte copying while preserving input, prediction and rollback-floor ownership.

- Improve driver handling of repeated identical local samples. Each player submits once after the complete list passes validation.

### Changed

- **Breaking**: Change the replay file format to version 4. Every frame now carries the digest of its own input row, so a corrupted input is refused with `DESYNC` at the frame that owns it - including a row in front of a frame that carries no state checksum. Version 1, version 2 and version 3 files are refused with `UNSUPPORTED_VERSION`. A recording now spends 16 more bytes per frame, so the largest recording a configuration can hold is smaller.

- Name the reason the replay viewer refuses a file. An older format version, a malformed file and an oversized file each get their own message.

- Build the pinned relay server into one revision-keyed shared cargo tree instead of a per-run output directory. The executable is still published at `<output>/target/debug/signal-fish-server`, so every documented path and the build receipt keep working.

- Reuse the pinned relay server's compiled dependencies across builds and across the six SignalFish CI jobs. The build now keeps its crates at one fixed Cargo home, the CI caches the dependency tree, and the server itself is still rebuilt from the pinned source every time.

- Prune stale scratch and superseded container caches on every container start, and report the repository cache without modifying it.

- **Breaking**: Change exact endpoint byte budgets to reserve one extra local input frame for acknowledged-input recovery.

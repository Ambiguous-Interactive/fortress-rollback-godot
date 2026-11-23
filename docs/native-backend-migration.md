# Native backend migration contract

[Issue #444](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/444) owns the switch to upstream Fortress.
Use this contract to qualify a native candidate and review changes to the release scope.
The [supported features](supported.md) still apply to projects using the GDScript addon.

## Session boundary

The game owns simulation, input encoding, and complete deterministic state.
The native class owns prediction, confirmation, rollback requests, snapshot cells, and upstream packet encoding.
The Godot driver owns the tick loop, transport routing, callback dispatch, and game-facing lifecycle.
Keep input data and game snapshots in byte arrays. Do not depend on native memory layout or object identity across callbacks.

Use the existing driver shape as the migration entry point. Keep game callbacks synchronous and ordered.
A save returns the complete snapshot of the requested frame before that frame advances.
A load restores the requested snapshot and reports success. Advance consumes one ordered row of input bytes and statuses.
The native adapter copies snapshot bytes at the boundary. A failed callback stops the step and ends the match.
Corrective load and advance callbacks can run during a waiting tick. Only a newly completed frame consumes the pending local input.
Publish lifecycle events after stepping, so application callbacks cannot start a second step inside the current one.

| Contract | Experiment evidence | Candidate gate |
| --- | --- | --- |
| Session construction | Two slots, one local slot and one remote address, zero input delay, upstream default prediction window | Validate a frozen roster of 2–8 total slots. Qualify multiple local slots and document the accepted prediction and delay settings before exposing them. |
| Inputs | Exactly four bytes per slot. The witness encodes its sample as little-endian u32. | Begin driver qualification with the four-byte schema. Identify the schema and game rules before session start. Projects using other widths stay on the legacy addon until they adopt a compatible schema or an additional width qualifies. |
| Sync test | Two through eight local slots, check distance two, checksummed snapshots | Preserve divergence reporting and qualify local sync tests with real game callbacks. The checksum-free experiment entry point is for benchmarking. |
| Transport | Bounded queues for one pre-associated endpoint. The exported test uses an HTTP-to-UDP bridge. | Preserve authenticated endpoint association, receive and send bounds, and draining during synchronization and stalls. Qualify direct, relay, and mixed routes separately. |
| Disconnect | The callback status can represent disconnected input. | Define how the driver reports interruptions, prediction stalls, room departure, and history loss. A disconnected input status alone gives no guarantee about coordinated drop. |

See the [experiment API](../experiments/gdextension/README.md) for the methods that exist today.

The opt-in driver entry point is `FortressDriver.configure_native(endpoints, game, snapshot_limit)`.
The input array lists endpoint IDs in frozen slot order. Use zero for local slots
and assign every authenticated remote endpoint a stable ID from 1 to 8. An
endpoint can own multiple slots. Supply four bytes per local slot in ascending
slot order through `step_local(now_us, inputs)`. After a waiting result, pass the
same sample or omit it with an empty byte array. Drain and route native datagrams
with `drain_native_packets()` and `receive_native()` even during waits.
`receive_native_result()` distinguishes full queues from rejected packets
so a transport can retry the original datagram after servicing the driver.
The driver uses the existing `save_state`, `load_state` and
`simulate_frame` callbacks and expires views when each callback returns.

The [playable example](online-example.md#try-the-native-backend) selects the
backend explicitly and uses one local slot per participant. The SignalFish
room namespace includes the pinned backend, input and game schema, room size
and initial route. Both byte routes add the same 16-byte room/roster tag.
The raw binding used for stock Rust interoperability carries no room tag.

The exported four-player recovery cases begin with one direct link unavailable
or close it after the match starts. Each case compares at least 40 confirmed input rows
and canonical snapshots, including samples after the close. The live-close case then withholds gameplay on both
routes to exercise the upstream disconnect timeout with the SDK roster intact.
Automatic direct restoration requires a replacement link within the same room
and plan. [SignalFish SDK #585](https://github.com/Ambiguous-Interactive/signal-fish-client-godot/issues/585)

## Protocol and saved data

Native gameplay packets use the codec in the [pinned upstream crate](reference/pins.json).
A stock Rust peer must use the same pin, input schema, slot map, and compatible session settings.
The [experiment results](experiments/upstream-binding.md) qualify that combination for two players with four-byte inputs and the documented settings.
A room must choose the backend and wire schema before delivering gameplay bytes. Refuse mixed legacy and native rosters at admission.
Finish an existing match on the backend on which it began. Upgrade the room server configuration and participating clients together before starting a native match.

Legacy gameplay datagrams and runtime snapshots belong to their original backend. There is no in-place session conversion.
Application save bytes can move if the new game callbacks preserve the application's snapshot format and rules. Prove it with old saved bytes before claiming compatibility.
Recording, spectator and diagnostic formats have their own version and checksum domains. A codec change in the gameplay layer cannot silently replace those formats.

| Existing surface | Migration and acceptance |
| --- | --- |
| Driver, expert API, typed lifecycle and external-input sessions | Adapt the driver first. Keep expert batches and external-input callers on the legacy path until their ordered request, error and ownership guarantees have replacements. See [local sessions](session.md), [fixed peers](peer-session.md), and [#40](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/40). |
| Delay increases and advisory measurement | Preserve fixed delay in the initial driver contract if qualified. Keep callers that rely on live retuning or delay suggestions on the legacy path pending dedicated tests. |
| SignalFish membership, binary relay, WebRTC, and fallback | Keep the SDK optional and reuse the room and transport boundaries where possible. Qualify backend agreement at admission, opaque upstream gameplay bytes on each route, path switching and browser recovery. See [#38](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/38) and [#75](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/75). |
| Coordinated drop and donor repair | Existing matches keep the legacy barrier. Pin the native disconnect behavior first. Keep the coordinated feature behind its agreement, history and live-browser gates. See [#48](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/48) and [#166](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/166). |
| Existing recording files and playback navigation | Keep the legacy reader and playback path available. Before changing the writer or default player, compare old recording fixtures, final state, frame navigation, and browser downloads. See [#45](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/45) and [#290](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/290). |
| Authenticated spectator playback | Keep existing v3 streams on the legacy path. A native publisher must export confirmed inputs, finalized statuses and startup state that legacy readers can validate, or introduce a separately negotiated format and keep old playback available. See [#47](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/47) and [#245](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/245). |
| Diagnostics and desync files | Preserve the legacy reader and export path. Expose versioned native reports with enough frame, checksum and input history to diagnose failed agreement, and test browser downloads. |
| Redundant spectator hosts and hot join | Keep as independently gated work. See [#49](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/49) and [#50](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/50). |

## Delivery and retirement

The experiment qualified fresh addon archives on both Godot pins across Linux, Windows, Apple Silicon macOS, Web, Android emulator and iOS Simulator.
Keep the Godot 4.3 floor and test both pins. Require installation from a prebuilt archive and an exported game for each claimed target.
The native archive installs the GDScript runtime and the platform extension together. Qualification installs both from that archive in clean projects.
The SignalFish SDK and example projects are separate inputs. See the [installation instructions](../experiments/gdextension/README.md#install-and-use).
Qualify physical devices and signing under [#452](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/452) before claiming mobile release support.
Qualify real 2/4/8-peer browser rooms, Linux Chromium, Firefox, WebKit and mixed browsers against [#39](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/39) and [#44](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/44).
The single-threaded Web experiment establishes extension loading and mixed-peer rollback.

For each claimed behavior, link evidence at the affected roadmap issue before superseding its acceptance criteria.
Use the pinned upstream tests for engine behavior and retain Godot tests for request order, the language boundary, transports, and compatibility with saved artifacts.
Apply the existing reviewed pin-upgrade process to the native dependency. Repeat package and interoperability qualification before switching pins.
After the replacement gates pass, switch the driver default, retire only the covered legacy runtime paths, and keep any compatibility readers and fixtures still in use.

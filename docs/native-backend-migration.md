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
slot order through `step_local(now_us, inputs)`. The installed-addon witness
covers consecutive and interleaved shared slots, including sparse endpoint IDs.
After a waiting result, pass the same sample or omit it with an empty byte array.
Drain and route native datagrams with `drain_native_packets()` and
`receive_native()` even during waits.
`receive_native_result()` distinguishes full queues from rejected packets
so a transport can retry the original datagram after servicing the driver.
`native_terminal_endpoint()` returns the configured remote endpoint ID from
the first native disconnect. It returns zero until an endpoint is known,
including after a room departure or when running with an older native addon.
The driver uses the existing `save_state`, `load_state` and
`simulate_frame` callbacks and expires views when each callback returns.

The [playable example](online-example.md#try-the-native-backend) selects the
backend explicitly and uses one local slot per participant. The SignalFish
room namespace includes the pinned backend, input and game schema, room size
and initial route. Both byte routes add the same 16-byte room/roster tag.
The raw binding used for stock Rust interoperability carries no room tag.

The exported four-player cases cover a missing startup link, a sustained
gameplay outage and temporary direct closes. Each compares at least 40
confirmed input rows and canonical snapshots. The sustained outage holds
gameplay on both routes until native disconnect while the SDK roster stays
intact. The temporary close holds replacement signaling while the pair
exchanges gameplay over relay. Once released, a fresh reciprocal channel
carries gameplay over WebRTC without changing the accepted plan or room.
Unaffected links stay direct throughout.

The overlapping close cell closes two pairs in one match, discards the first
replacement Offer for one pair, and requires gameplay on both fresh links.
It runs with Chromium and alternating Chromium–Firefox on both Godot pins.
The receipt identifies each replacement by its exact signaling envelope and
reciprocal ICE credentials. A local control withholds all replacement Offers
for the second pair and reports which pair is still missing.

WebKit receipts distinguish application channel close calls, channel close
events and peer connection close calls. Each observation keeps its browser
timestamp and controller receipt, even when the final page read times out.
Tagged send diagnostics list the matching reciprocal route and the possible
gap to each observed stage when the page clocks are bounded. Nonce-matched
same-origin HTTPS exchanges bracket each page clock with controller receipt
and response timestamps. The receipt keeps the HTTPS and debugger samples so
an ambiguous interval can be reproduced. Acceptance requires a fresh SCTP
abort or completed connection close followed by the tagged send, with at least
2 ms between the latest possible close and earliest possible send.

To isolate a hosted browser failure on both Godot pins, select the room in the
manual workflow dispatch.

```sh
gh workflow run gdextension-experiment.yml -f qualification=chromium-webkit -f cell=relay:8
gh workflow run gdextension-experiment.yml -f qualification=chromium-firefox -f cell=mesh-recovery-overlap:4
```

The run name identifies the browser profile and room. Keep the default `cell=all`
for full browser qualification. Selecting one room with the default platform
profile runs that room in Chromium on Web.

Use the traced server for an exact packet comparison on the same cell.

```sh
gh workflow run gdextension-experiment.yml -f qualification=firefox -f cell=relay:8 -f relay_trace=true
```

The traced run builds the pinned server with receipt hooks on each Godot pin.
The job artifact includes the build receipt and log, the browser log, and any
published server scope and packet snapshot. Pair each traced run with a stock
run at the same revision, browser profile, and room size to measure overhead.
The browser receipt counts valid native room broadcasts separately from
addressed packets. Validate the native header before filtering and decode
sender identity only for the recipient's own traffic.

Ordinary receipts include up to 128 records per directed link and stage.
When a native expiry identifies links to diagnose, the browser and server
publish only those links. Their input and quality histories expand to at most
512 records per stage. Count and omitted fields still describe the full stream.

During the traced gameplay hold, the `relayHold` receipt covers both directions
between the first two UUIDs in the sorted frozen roster. Each page publishes its
first 512 quality sends and raw arrivals per stage in console batches. Capture
ends at release, terminal failure, the hold cap, or 45 seconds of page time.
Previously received batches survive a final page-read timeout. The regular
hold summaries still cover every link.

Each packet row names its directional endpoints, token and any known delivery
stamp. Join a browser send to ingress by its single socket's ordinal and exact
envelope. Join ingress, addressed writes and raw arrivals by stamp and exact
envelope. The reply's recorded native acceptance candidates identify matching
report stamps on the reverse link. All observed candidates stay visible,
including when a candidate has no joined report row during the hold. Empty
stages can reflect an observation gap or eviction. Compare ingress and write
on the server clock. Compare sends and arrivals from the same page on its
page clock. The receipt preserves each clock and includes no cross-clock
duration.

Use the same-link pressure control with a local traced server build receipt.
The control drops addressed packets after raw arrival for one link while
the sender sends 129 inputs and 129 quality reports. It joins the earlier
accepted packets across all stages, verifies the drop boundary and resumes the
link before the normal correction, confirmed-history and departure checks.

```sh
python3 scripts/reference/native_online_probe.py --version "$GODOT_PIN" --cell relay:8 \
  --relay-trace-server "$TRACE_BUILD_RECEIPT" --relay-same-link-control \
  --addon "$WEB_ADDON" --output "$OUTPUT"
```

Eight-player relay receipts include warmup checkpoints from each browser.
A checkpoint records exact sampled quality-report bytes at browser receipt,
SDK delivery, and native enqueue on the same page clock. Its recipient,
observation interval, queue samples, and cutoff remain available if the final
renderer read times out. A missing observation can reflect sampling, eviction,
or the end of observation. Identical repeated bytes can obscure per-packet
latency. Native enqueue represents accepted input to the native socket queue.

The `releaseTiming` receipt follows each prepared request by its unique path.
The controller records request dispatch, receipt, header preparation,
handoff to `end()`, and HTTP finish. The page records the fetch continuation
and the matching Resource Timing entry. Fetch start follows controller
dispatch. Network request start precedes controller receipt, and response
end follows host handoff. The `offset_ms` bracket uses these causal edges
with 2 ms allowed for page clock precision. A missing network request start
falls back to fetch start. The receipt retains response start for diagnosis.

`write_to_response_end_ms` starts at header preparation.
`handoff_to_response_end_ms` starts at the call to `end()`. Both include the
clock uncertainty and cap the latest possible response end at controller
receipt of its record. They require the matching HTTP 204. Missing or
inconsistent evidence leaves a delivery interval `null`. The hold-cap,
response-end and continuation observations share the same page clock.

The native browser workflow accepts `qualification=firefox`, `cell=relay:8`,
and `release_controls=true`. On each Godot pin, one runner executes the stock
eight-player room, Firefox relay:4, Chromium relay:8, and both delay controls.
Each attempt writes to its own directory and a failing room leaves the workflow
red. The delivery control waits 450 ms between preparing the response and
ending it. The continuation control waits 450 ms after Fetch resolves and
before the page starts releasing packets. Both require a measured interval
at the selected boundary and use the regular packet cap and correction deadline.

Run one control locally with the normal pinned browser setup.

```sh
python3 scripts/reference/native_online_probe.py --version "$GODOT_PIN" --browser-pair firefox --cell relay:8 \
  --release-delay "$DELAY" --addon "$WEB_ADDON" --output "$OUTPUT"
```

Set `DELAY` to `delivery` or `continuation`. A room that stops during warmup
or prediction stall has yet to apply either delay.

Relay receipts separate the first corrected confirmation, the next advancing
physics turn, and history publication. The normal 40-frame target is observed
immediately. If the comparison expands to cover later samples, the page uses
its bounded turn history to report the original crossing. Compare controller
receipt against the controller deadline. The page's observation and emission
timestamps show how long a backfilled observation waited on that page.

Departure receipts name the remote UUID and its one-based endpoint in the
frozen roster. Native expiry is sampled before failure cleanup. SignalFish
player removal is sampled when the SDK emits `player_left`. Compare their order
within each survivor's clock, and use controller receipt times to relate the
survivor events to the leaving page's command. Missing receipts leave the
corresponding event unobserved.

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
The [playable Web qualification](experiments/upstream-binding.md#playable-web-rooms) runs the installed native addon through actual SignalFish rooms.
The single-threaded Web experiment establishes extension loading and rollback against a standalone Rust peer.

For each claimed behavior, link evidence at the affected roadmap issue before superseding its acceptance criteria.
Use the pinned upstream tests for engine behavior and retain Godot tests for request order, the language boundary, transports, and compatibility with saved artifacts.
Apply the existing reviewed pin-upgrade process to the native dependency. Repeat package and interoperability qualification before switching pins.
After the replacement gates pass, switch the driver default, retire only the covered legacy runtime paths, and keep any compatibility readers and fixtures still in use.

# Native spectator relay dependency qualification

Issue [#131](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/131)
requires an exported Fortress spectator game over SignalFish.
The historical experiment below qualifies the SDK's normal native relay path only.
The [Fortress native witness](#fortress-native-witness) now exercises the production
Fortress adapters with a separate authenticated loopback control fixture. Neither
experiment qualifies exported spectator games or the complete lifecycle matrix.
The [exported Chromium viewer](#exported-chromium-viewer) below separately qualifies viewing with a native host on both engine pins.

## Executed sources and results

Measured on 2026-10-23, Linux arm64:

| Input | Revision or result |
| --- | --- |
| Current SDK and unchanged upstream drill | `dc5302b43053e6439d4d89cb89a9666111510936` |
| Fixed server | `182cb234c7aa601be3c2aad881948b3c5b853aaa` |
| Reviewed SDK comparison | `db7d30f228d8d564adcb2eb38d5983bf6b9877ac` |
| Reviewed server negative control | `9c2fb8fa635a69241b8ccf38be651d561fef7434` |
| Current SDK, fixed server, Godot 4.3 | Exit 0; eight spectator cases and Direct recovery pass |
| Current SDK, fixed server, Godot 4.7.2 | Exit 0; same complete case inventory passes |
| Reviewed SDK addon, fixed server, Godot 4.3 | Exit 0; same complete case inventory passes |
| Reviewed SDK addon, fixed server, Godot 4.7.2 | Exit 0; same complete case inventory passes |
| Current SDK, reviewed server, Godot 4.3 | Exit 1; `timed out: live roster join`; no case success |

The reviewed SDK comparison copies its 28 addon files from the verified pinned
archive. Every relative filename and SHA-256 matches that archive. It uses the
unchanged current drill and project warning configuration, rather than claiming
that this newly added drill existed in the old SDK revision.

The fixed server was built with Rust 1.94.0 using
`cargo build --locked --no-default-features --bin signal-fish-server`.
Its revision-keyed target tree is outside the scratch source tree.
The binary SHA-256 is
`84334ca8e66bbd95a43b6e6d9e9527d1a3f334090a5c0ab489269f1e46b6dcbf`.
The old-server control uses the existing pinned build receipt and verifies its
binary SHA-256, `501b4858cd57b547e692eaeb0ddf9239081685d721dcd0dcb9c856df3dcba556`.
Its failure occurs after spectator admission: live player membership never arrives.

Each engine matches the executable extracted from its digest-verified archive
in [pins.json](pins.json). Executed engine SHA-256 values:

| Engine | SHA-256 |
| --- | --- |
| 4.3 | `8b8d7c6089d8b4238e6ec872f027ef1a4bfc5241ddb5f8aec452b058368d255b` |
| 4.7.2 | `3fcb80f4fe794e3859360eb641d8c41d8ffe2c2e54ba1981e55a76851d5ed1f4` |

The two candidate source inventories and the server executable remain unchanged
across both runs. Each run starts a separate server process, waits for its local
socket, and terminates and waits for that owned process after the drill.

Machine-local artifacts are
`.cache/scratch/spectator-qualification/qualification.json`,
`.cache/scratch/spectator-qualification/pinned-sdk-qualification.json`,
`.cache/scratch/spectator-qualification/sdk-4.3.log`,
`.cache/scratch/spectator-qualification/sdk-4.7.2.log`, and
`.cache/scratch/spectator-qualification/old-server-sdk-4.3.log`.
The receipts retain source inventories, commands, executable hashes, exit codes,
and the complete marker list. These artifacts are diagnostics, not a baseline gate.

## Reproduce the drill

Use separate source checkouts at the exact SDK and server revisions above.
The SDK script is
[`tests/smoke/run_live_server_acceptance.gd`][drill].
The upstream [instructions][instructions]
describe the same public SDK boundary.

1. Check out server `182cb234c7aa601be3c2aad881948b3c5b853aaa` and build it
   with the command above. Use the pinned Rust executable and a shared
   revision-keyed `CARGO_TARGET_DIR`; do not put build output in each run folder.
2. Copy `config.example.json` to a run-owned config. Set `port` to an available
   loopback port; set `session.default_topology` to `host` and
   `session.enable_webrtc` to `false`. Enable
   `protocol.enable_rkyv_game_data` and `protocol.enable_protobuf_game_data`.
   Set `rate_limit.max_room_creations` and `rate_limit.max_join_attempts` to 1000.
3. Start the built server with that config in `SIGNAL_FISH_CONFIG_JSON` and
   `RUST_LOG=error`. Wait for the local socket while checking the process is live.
4. Run each verified engine against SDK `dc5302b4`:

   ```sh
   godot --headless --path <sdk-checkout> --script res://tests/smoke/run_live_server_acceptance.gd -- ws://127.0.0.1:<port>
   ```

5. Require exit zero, no engine errors, and exactly the complete markers below.
   Stop and wait for the server before the next engine run.
6. For the pinned-SDK comparison, copy the reviewed SDK addon into a separate
   minimal project with the current SDK project configuration and unchanged
   drill. Compare all addon files to the verified pinned archive before execution.
   Repeat against the same fixed server with both engines.
7. For the old-server control, retain the current SDK and replace only the
   executable with the hash-checked reviewed server. Require exit one,
   `timed out: live roster join`, and no spectator success marker.

The upstream script has eight-second phase deadlines and a two-minute watchdog.
The experiment additionally imposes a 150-second subprocess deadline.
Its ten required markers, in order, are:

```text
LIVE_SPECTATOR_PASS v2 json decoded=false
LIVE_SPECTATOR_PASS v2 message_pack decoded=false
LIVE_SPECTATOR_PASS v2 message_pack decoded=true
LIVE_SPECTATOR_PASS v3 json decoded=false
LIVE_SPECTATOR_PASS v3 message_pack decoded=false
LIVE_SPECTATOR_PASS v3 message_pack decoded=true
LIVE_SPECTATOR_PASS v3 rkyv decoded=false
LIVE_SPECTATOR_PASS v3 protobuf decoded=false
LIVE_DIRECT_PASS refresh successor relay gameplay
LIVE_SERVER_ACCEPTANCE_PASS
```

The drill verifies cached spectator baseline before the callback, live roster
join/leave, lobby readiness, public GameStarting, sender and encoding identity,
unchanged spectator role, absence of personalized plans, and voluntary leave.
It requires `spectator_relay` in v3 ProtocolInfo. The v2 result applies only
to this measured deployment; v2 alone cannot advertise that capability.
The Direct case separately verifies endpoint refresh, host succession, Relay
reset, and subsequent gameplay. It supplies no spectator rollback evidence.

## Historical pin review and remaining acceptance

[SDK PR #373](https://github.com/Ambiguous-Interactive/signal-fish-client-godot/pull/373)
is merged. SDK main Runtime CI [39993743131](https://github.com/Ambiguous-Interactive/signal-fish-client-godot/actions/runs/39993743131),
LLM Harness, and Docs Validation all pass at `dc5302b4`.
The remaining SDK [#368](https://github.com/Ambiguous-Interactive/signal-fish-client-godot/issues/368)
work concerns concurrency, delivery pressure, and room-switch races.

Candidate server main CI [39951100611](https://github.com/Ambiguous-Interactive/signal-fish-server/actions/runs/39951100611)
fails its Dependency Audit job. `cargo-deny` and root/native/fuzz `cargo-audit`
reject `ctutils 0.4.3`, advisory `RUSTSEC-2026-0385`; the reported solution is
`>=0.4.4`. Successful local relay execution does not clear that gate.

The current SDK changes only two addon scripts relative to the reviewed pin.
They add spectator read-only send guards, clear stale seated identity when
installing a spectator baseline, and track player epochs for mesh fencing.
Normal relay receipt already works with the reviewed addon against the fixed
server. These lifecycle changes still require their own review and acceptance.

The complete SDK diff spans 40 files. The server diff spans 529 files, including
48 under `src`, plus protocol/build/dependency changes and vendored RTC code.
An unreviewed whole-source upgrade would include much more than spectator routing.
The next implementation must:

- Resolve or explicitly adjudicate the candidate server audit failure upstream.
- Review server spectator routing, baseline-before-publication ordering, protocol
  capability, delivery generation, detach, and all other drift before advancing pins.
- Review SDK read-only guards, stale seated identity, player epochs, and mesh fences.
- Build a bounded Fortress spectator adapter without seating viewers or changing
  player confirmation. Use fresh authenticated stream identities and agreed keys.
- Run actual exported games on both engine pins: host rollback, pause/catch-up,
  lost tail, strict expiry, host loss, and fresh-room replacement.
- Retain the upstream differential/model and concurrent-publication limitations
  in [#47](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/47)
  and #131 until their required evidence exists.

This evidence removes uncertainty about normal SDK receipt against the fixed
server. It does not close #131 or advertise live Fortress spectator support.

[drill]: https://github.com/Ambiguous-Interactive/signal-fish-client-godot/blob/dc5302b43053e6439d4d89cb89a9666111510936/tests/smoke/run_live_server_acceptance.gd
[instructions]: https://github.com/Ambiguous-Interactive/signal-fish-client-godot/blob/dc5302b43053e6439d4d89cb89a9666111510936/docs/testing.md#live-server-acceptance-opt-in

## Fortress native witness

Run `scripts/reference/signalfish_spectator_live.py` after building the current
pinned server. Supply the build receipt, source tree and verified editor used by
that build's integration run:

```sh
python3 scripts/reference/signalfish_spectator_live.py \
  --godot godot \
  --server .cache/reference/results/signalfish-server-build/target/debug/signal-fish-server \
  --server-source .cache/reference/signal-fish-server-8cbf5d9e5dc155e7a7a4f8f5593f0a24f8aaa560 \
  --build-receipt .cache/reference/results/signalfish-server-build/build-receipt.json \
  --output .cache/reference/results/spectator-live
```

Repeat with each pinned engine. The launcher matches the supplied editor bytes
against its verified release archive. It verifies the server build provenance,
SDK archive, authored helpers and copied sources before execution, then rechecks
those identities after stopping the owned server and control service.
A failed run cannot leave a successful `spectator-live.json` receipt.

The native process opens two seated SDK sockets and one separate read-only
spectator socket. The production `FortressSignalFishSpectatorHost` sends OFFER,
confirmed rows and END through the real SignalFish server. The production viewer
relay receives the actual SDK-attributed bytes. The viewer never obtains a seat.

A bounded loopback HTTP fixture uses fresh host and viewer bearer capabilities.
The host binds admission to the SDK's actual spectator roster. The viewer obtains
the original state, neutral input, dimensions, seed, rules, stream identity and
key through its authenticated admission response. ACCEPT returns through that
separate authenticated service, then reaches the production publisher's
`receive_accept()` boundary. Foreign capabilities and another viewer identity
must receive HTTP 403. Altered state, seed, rules, neutral input, dimensions and
digest must fail the viewer's configuration checks before playback.

Success requires all 48 original canonical boundaries, actual host rollback,
viewer-specific physical binary receipts, eight paused host frames, bounded
catch-up and clean final completion. The independent expected-state calculation
uses the original scripted input transcript. The seated host's confirmed frontier
must finish at frame 47 and its SDK roster must remain two players.
The same native flow runs three final-drain failure controls with `--late-signal`:
`spectator_join_failed`, `spectator_left` and selected `spectator_disconnected`.
Each must exit at the expected late failure without printing a success marker.

Use `--departure host` or `--departure viewer` for physical socket-loss cells.
At host frame 20 the viewer is paused with at least two actual buffered rows.
The selected SDK client closes its socket. The surviving remote SDK must report
that exact host or viewer departure through the real server before success.
Both cells require terminated playback with unchanged canonical bytes and a
stopped publisher. Viewer departure additionally requires the seated host to
repair its original inputs and advance through canonical boundary 21.
These cells and the final-drain controls run on both pinned native engines in CI.

This fixture is development tooling, not a production identity provider. Both
SDK roles run in one native process; seated remote input uses an injected
schedule, while spectator data and acceptance use real sockets. The exported
browser witness, replacement and remaining loss matrix, production admission
service and full upstream semantic acceptance remain in #131 and #47.
[Issue #245](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/245) specifies the next exported-browser witness.

## Browser admission control boundary

`Control(allowed_origin="http://127.0.0.1:PORT")` enables one exact browser
origin for the development admission fixture. Supply the actual served page's
origin, including its port. The default refuses browser-origin requests and
preserves the native originless HTTP flow.

A valid browser preflight permits GET/POST with Authorization and Content-Type.
Foreign, opaque (`null`) and duplicate origins are refused; no wildcard origin
or ambient credential access is enabled. Origin permission does not grant a
role: the host and viewer still need their separate bearer capabilities.

Run the ordinary bounded HTTP controls with:

```sh
python3 -m unittest discover -s scripts/reference -p test_spectator_control.py
```

The actual Chromium fetch test runs when both explicit tool paths are supplied:

```sh
FORTRESS_PLAYWRIGHT_PACKAGE=/absolute/path/to/node_modules/@playwright/test \
FORTRESS_CHROMIUM_EXECUTABLE=/absolute/path/to/pinned/chrome \
python3 -m unittest discover -s scripts/reference -p test_spectator_control.py
```

It serves two local origins and exercises authenticated admission, ACCEPT and
host retrieval through real browser preflights. It also verifies wrong-role,
foreign-origin and unapproved-header rejection. Without both tool paths, this
browser case is explicitly skipped; the HTTP controls still run.

This qualifies the fixture's browser HTTP boundary only. It does not execute an
exported Godot game, establish independent host/viewer browser lifetimes or
qualify SignalFish browser spectator routing. Those requirements remain in #245.
The fixture continues to leave production identity policy to the application.

## Exported Chromium viewer

`signalfish_spectator_live.py --browser-viewer` runs the production viewer stream,
SDK relay adapter and game driver in an actual release Web export. The selected
viewer owns a separate Chromium context and SDK socket; the native host and
second seated SDK client run in a separate process. The browser receives only
its viewer capability. Authenticated cross-origin HTTP requests provision the
room, selected spectator identity and original state, and carry ACCEPT back to
the native publisher. OFFER, original confirmed rows and END use actual SignalFish
binary relay. The viewer never receives a seated player identity.
Pending control resources return authenticated HTTP 202, with bounded polling delays;
denied capabilities and unknown paths retain error responses and rejection accounting.

Success requires 48 independent canonical boundary comparisons, actual host
rollback, viewer-specific binary receipts, a paused buffered tail, bounded
catch-up and clean END. The native host independently checks its repaired final
state, confirmation 47 and unchanged two-player roster. Both processes and the
server have deadlines; browser socket closure and owned process teardown precede
receipt publication. Sources, copied scripts, imported metadata, exported files,
pinned engine/templates/browser and SDK/server identities bind the receipt.

Add `--browser-fault initial-state` for a controlled altered admission state.
It must reach the exported viewer's original-state rejection before ACCEPT or
playback. A healthy control must complete all canonical comparisons. CI runs
both cells on Godot 4.3 and 4.7.2 with pinned Chromium.

This is viewer browser acceptance, not the complete #245 witness. The host and
second seated client remain native; remote seated game inputs still use an
injected schedule. Exported host gameplay, actual remote seated input transport,
replacement/loss and additional browsers remain unqualified. The loopback bearer
fixture remains development tooling; applications own production identity policy.

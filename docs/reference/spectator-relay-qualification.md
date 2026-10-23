# Native spectator relay dependency qualification

Issue [#131](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/131)
requires an exported Fortress spectator game over SignalFish.
The experiment below qualifies the SDK's normal native relay path only.
It does not advance reviewed pins, establish the Fortress witness, or qualify
pressure, concurrent publication, room replacement, or browser behavior.

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

## Pin review and remaining acceptance

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

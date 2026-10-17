# Online two-player example

Open `examples/online/online.tscn` to play the existing integer movement game
with someone in another browser. The scene uses real SignalFish signaling,
WebRTC bytes and the bounded binary relay fallback coordinator. WASD or arrow
keys control your own numbered player. The sorted full player UUID roster
assigns numbers, so the room creator is not necessarily player one.

![The exported scene after actual online movement](online-example.png)

The SignalFish SDK is optional. Without it the scene opens and explains how to
install it; the root addon and other examples remain runnable. This example
requires an initial WebRTC mesh plan with relay support available in standby.
An initial relay-only plan is reported as unsupported. It keeps the same
rollback session when an established direct link falls back to relay.

## Install and run

Start from this checkout, with Python 3 and a Godot **4.3** or **4.7.2** executable.
Install that editor's matching standard export templates using **Editor > Manage Export Templates**.
Set `GODOT` to its absolute executable path. Repeat the flow with each editor when checking both pins.
The following commands use a new project and a separate tools directory:

```sh
GODOT=/absolute/path/to/godot
EXAMPLE_DIR=$(mktemp -d)
TOOLS_DIR=$(mktemp -d)
python3 scripts/reference/online_install.py --project "$EXAMPLE_DIR"
"$GODOT" --headless --path "$EXAMPLE_DIR" --editor --quit
"$GODOT" --path "$EXAMPLE_DIR"
```

The installer copies only the runtime addon, online/offline scenes and their dependencies,
licenses, a minimal project, and a Web export preset. It does not copy this checkout's
`.godot`, `.cache`, tests, server, compiler, scripts or native extensions. The project uses
60 physics ticks per second, the Compatibility renderer and a Web export without threads.
No plugin or autoload needs activation.

Before installing the SDK, press **Create room**. The scene must explain that SignalFish
is missing and name this guide. The [offline scene](offline-example.md) still runs:

```sh
"$GODOT" --path "$EXAMPLE_DIR" res://examples/offline/offline.tscn
```

Close the editor/game before adding files. Download and verify the optional SDK,
then install only its addon directory, including its license:

```sh
curl -fL https://codeload.github.com/Ambiguous-Interactive/signal-fish-client-godot/tar.gz/db7d30f228d8d564adcb2eb38d5983bf6b9877ac -o "$TOOLS_DIR/sdk.tar.gz"
echo "0854f8c778a118defe95bd8887e227c8bc8c194c54d2e501c6d74094fa43ec12  $TOOLS_DIR/sdk.tar.gz" | sha256sum -c -
tar -xzf "$TOOLS_DIR/sdk.tar.gz" -C "$TOOLS_DIR"
python3 scripts/reference/online_install.py --project "$EXAMPLE_DIR" \
  --sdk "$TOOLS_DIR/signal-fish-client-godot-db7d30f228d8d564adcb2eb38d5983bf6b9877ac"
"$GODOT" --headless --path "$EXAMPLE_DIR" --editor --quit
```

The pinned SDK needs no editor plugin or autoload. Use an existing compatible SignalFish
v3 deployment, or build the pinned local server below. Rust is needed only to build that
separate server; the installed Godot project needs neither Rust nor native WebRTC extensions.
Local browser ICE uses no STUN/TURN server and proves no public-network connectivity.

```sh
curl -fL https://codeload.github.com/Ambiguous-Interactive/signal-fish-server/tar.gz/9c2fb8fa635a69241b8ccf38be651d561fef7434 -o "$TOOLS_DIR/server.tar.gz"
echo "1c618785dd93e1a69f27687f1f8f75fbfb15e49f3a3a0f130aa3ee17af40a076  $TOOLS_DIR/server.tar.gz" | sha256sum -c -
tar -xzf "$TOOLS_DIR/server.tar.gz" -C "$TOOLS_DIR"
SERVER_SOURCE="$TOOLS_DIR/signal-fish-server-9c2fb8fa635a69241b8ccf38be651d561fef7434"
rustup toolchain install 1.94.0 --profile minimal
cargo +1.94.0 build --manifest-path "$SERVER_SOURCE/Cargo.toml" --locked --no-default-features \
  --bin signal-fish-server --target-dir "$TOOLS_DIR/server-target"
python3 scripts/reference/online_install.py --server-source "$SERVER_SOURCE" --port 8080 > "$TOOLS_DIR/server.json"
SIGNAL_FISH_CONFIG_JSON="$(cat "$TOOLS_DIR/server.json")" "$TOOLS_DIR/server-target/debug/signal-fish-server"
```

Keep that server running in its terminal. The generated configuration sets the application's
ID to `fortress-live-webrtc`, selects mesh/WebRTC, allows binary relay and removes external
ICE servers. The scene requests MessagePack binary game data. If the build needs system
packages, see the [server prerequisites](reference/README.md#setup-and-reproduction).

In another terminal with the same `GODOT`, `EXAMPLE_DIR` and `TOOLS_DIR` values,
export the production scene and generate a local development certificate:

```sh
EXPORT_DIR="$TOOLS_DIR/web"
mkdir -p "$EXPORT_DIR"
"$GODOT" --headless --path "$EXAMPLE_DIR" --export-release Web "$EXPORT_DIR/index.html"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost \
  -addext subjectAltName=IP:127.0.0.1 -keyout "$TOOLS_DIR/localhost.key" -out "$TOOLS_DIR/localhost.crt"
node scripts/reference/browser/online_host.cjs "$EXPORT_DIR" ws://127.0.0.1:8080/v3/ws \
  "$TOOLS_DIR/localhost.crt" "$TOOLS_DIR/localhost.key" 8443
```

The development host needs Node.js, but has no npm dependencies. It serves the correct
WebAssembly MIME type and proxies WSS to the separate loopback server. Open
`https://127.0.0.1:8443/index.html` in two Chromium windows. Accept your own generated
local certificate in each browser profile. Use `wss://127.0.0.1:8443/v3/ws` in both clients.
A secure page, including Chromium's localhost secure context, requires WSS.
For public hosting, replace this loopback helper with trusted HTTPS/WSS hosting and
configure ICE/STUN/TURN for your deployment. Native editor networking needs a separately
installed WebRTC implementation.

1. In the first browser, enter the WebSocket endpoint and player name, then
   press **Create room**. Copy the displayed room code.
2. In the second browser, enter the same endpoint, a player name and that code,
   then press **Join room**. The room is limited to two players.
3. Both players press **Ready**. The creator presses **Start** once both are
   ready. Network synchronization must complete before movement advances.
   Click outside text fields if a field still has keyboard focus.
4. Move with WASD or the arrow keys. The display reports your player number,
   frame, confirmed frame, input delay, stalls, latest event and active relay links.
5. On a laggy connection, press **=** to raise your input delay by one frame.
   Moves then take effect a frame later, with fewer corrections. Raises cannot be undone in this match.

## Diagnostics

The display shows completed rollback count, maximum restore depth, replayed frames and
active relay links. Press **Diagnostics** to download `fortress-diagnostics.json` in a browser
or copy JSON to the clipboard natively. Download before leaving a failed match.

The report includes frame/confirmation, completed-work counters, per-link backlog/RTT,
engine version and retained terminal causes. It excludes names, room/player/connection IDs,
SDK configuration and tokens. It uses no browser storage.

Game payloads stay excluded by default. To collect canonical evidence, select
**Include game state and inputs in diagnostics** before pressing **Ready**.
The choice freezes for that match. It retains at most 120 frames of local saved
state and applied inputs, with the game's seed and version. The first checksum
mismatch freezes that window; download it before leaving the failed match.
Review the game bytes before sharing. The checkbox affects only local diagnostics,
so the other player can keep capture disabled. New rooms use the checkbox's current
choice when you press Ready. See the [trace contract](peer-lifecycle.md#opt-in-canonical-divergence-evidence)
for payload bounds and missing-history limits. This example has no standalone replay command.
A checksum mismatch includes both checksum hex strings and the first mismatching frame.
The local canonical window is diagnostic evidence; full gameplay recording and replay
remain [separate work](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/45).

## Leave and restart

**Leave / new room** detaches the fallback coordinator, direct and relay
adapters, membership adapter and SDK objects. To restart, both players leave;
the creator creates a fresh room and shares its new code. Join that fresh room,
ready again and start again. The scene does not restart inside the old room.

A connection failure, membership change, reconnect or terminal rollback error
stops the old game, detaches its transport queues and WebRTC mesh, and closes its
SignalFish connection. A failure during an active send finishes queue cleanup
after the send unwinds. Failed ticks service the SDK close handshake without
advancing gameplay. The first failure message remains visible until Leave;
then establish a fresh room. Automatic SDK reconnect is disabled.
Rejoining a server room cannot recover rollback
history or authorize a new session over old packet queues.

The application match identity is a domain-separated 16-byte SHA-256 prefix
of the fresh room UUID, sorted full player UUIDs and fixed game/config revision.
It is separate from the raw room UUID and each random transport-incarnation ID.
A new room changes that identity. The simulation uses the existing seeded,
fully snapshotted integer game; host clock and transport entropy never enter its
state. Keyboard input is retained across prediction or queue stalls until that
original frame is accepted.

## Suspension and expiry

The caller polls elapsed monotonic protocol time before retrying retained output
or receiving buffered gameplay. Running games also service their protocol clock
before SDK callbacks can end the room. Refused output never freezes that clock.
After a brief scheduling pause, a live session can resume through prediction
repair without replacing its identity or input history. Each caller tick advances
at most one new simulation frame; elapsed seconds never become invented inputs.
Godot also bounds physics catch-up to eight ticks per rendered frame by default.
Each of the eight service rounds permits one additional protocol poll after
draining diagnostic pressure, before receiving buffered bytes. Freeing a full
event or trace bank must not allow a completion reply to overtake expiry.

The running protocol expires after more than two seconds without an accepted
remote packet. Initial rollback synchronization has a 30-second application
deadline. Exact deadline boundaries remain eligible. A due handshake timeout
remains observable when token or outgoing-packet capacity prevents another retry.
An expired game stops before buffered packets can refresh liveness. Leave and
create a fresh room; returning to the tab cannot resurrect old history.

## Verification

The existing browser launcher now starts with the same `online_install.py` command above.
It uses a new project and empty engine configuration, cache and data directories for each
engine. Before installing the SDK, it checks the actual missing-SDK status label and runs
24 offline frames against an independent canonical replay. It then installs the optional
SDK, imports and exports the unmodified production scene using the documented preset.
Only afterward does it add a development observer for the five-room browser flow below.
The observer records original submitted inputs and corrected state; it does not replace
simulation or transport implementation. The fixture uses the same HTTPS/WSS host as the
manual commands. Its owned server uses the same generated configuration with higher
traffic ceilings for repeated fault scenarios.

Run the regression after the [source-bound server build](signalfish-relay.md#reproduce-native-server-delivery):

```sh
python3 scripts/reference/signalfish_webrtc_probe.py --online-example \
  --server .cache/reference/results/signalfish-server-build/target/debug/signal-fish-server \
  --server-source .cache/reference/signal-fish-server-9c2fb8fa635a69241b8ccf38be651d561fef7434 \
  --build-receipt .cache/reference/results/signalfish-server-build/build-receipt.json \
  --output .cache/reference/results/online-example
```

Both pinned engines run by default. Receipts record the exact install/export commands,
engine versions, source/tool hashes, clean installation inventories, offline canonical
state, browser input/rollback evidence and rendered `VERSION-online.png` screenshots.
CI runs the same command for Godot **4.3** and **4.7.2** with pinned Playwright **1.56.1**
and Chromium **141.0.7390.37** on Linux. Firefox, WebKit, mixed browsers, native WebRTC,
public hosting and WAN/NAT/TURN remain unverified release gates under
[browser coverage #39](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/39).
The harness can reuse verified tool archives; none of that development cache enters the
installed project or its fresh engine user directories.


`tests/unit/test_online_example.gd` covers optional SDK scene loading, room
identity validation, real two-peer protocol startup over SDK transport doubles,
prediction stalls and held input recovery, caller-owned refusal retries and
terminal callback ordering. It runs through the ordinary headless test runner
with deterministic and fresh-process repeats. These injected tests establish
application behavior; exported browser evidence is a separate verification gate.

`tests/unit/test_online_startup.gd` delays one peer's final handshake reply
behind original gameplay on both direct and relay paths. Later keys change;
both peers must recover the exact earlier bytes. Valid early traffic is inert
until synchronization completes, and malformed traffic remains rejected.

`tests/unit/test_online_lifecycle.gd` covers exact expiry boundaries, retained
send pressure, saturated handshake tokens and bounded short-suspension recovery.
The browser witness pauses both actual Chromium page threads through acknowledged
CDP debugger commands. It measures host/protocol clock gaps, corrected original-input
prefixes after a short pause, and actual frozen frames after an overdue pause.
This controlled execution pause does not establish hidden-tab policies, operating
system sleep or Firefox/WebKit behavior.

The same exported witness verifies that overdue games close their signaling
sockets before Leave. It then cuts both actual signaling socket pairs during
another active game, requires frozen terminal frames and physical connection
cleanup before Leave, and plays a fresh room with a new rollback identity.
A separate fourth-room stage kills the owned server process during gameplay,
with retained relay sends and one delayed original input per peer. It verifies
the process exit, frozen failed frontiers, unchanged recovery messages and full
connection cleanup before Leave. The same binary/configuration restarts on the
same endpoint with a different live process handle and bounded readiness checks.
Both players explicitly Leave, then play a fifth room with fresh room and rollback
identities. Original old-room bytes sent over the new direct channels are counted
and discarded; corrected prefixes still match the new original keyboard inputs.
The witness also invokes captured old SDK info, room, ready and error callbacks
after the fifth game starts. Connection revisions fence those callbacks; they
cannot change the fresh game, readiness, protocol configuration or message.

This proves explicit fresh-room recovery after socket outage and server-process
death. It does not reconnect or restore an existing match. Restoring ICE, SDK
replans, WAN/NAT/TURN and the full browser matrix remain separate acceptance
cases under [the lifecycle issue](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/38).

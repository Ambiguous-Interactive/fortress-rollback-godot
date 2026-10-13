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

1. Obtain the pinned SDK revision
   `db7d30f228d8d564adcb2eb38d5983bf6b9877ac` from
   [signal-fish-client-godot](https://github.com/Ambiguous-Interactive/signal-fish-client-godot/tree/db7d30f228d8d564adcb2eb38d5983bf6b9877ac).
   Copy its `addons/signal_fish` directory into your project's `addons/`.
   Preserve its license. The example loads SDK scripts at runtime and does not
   require its editor plugin or autoload.
2. Run a SignalFish v3 server with an application entry whose ID is
   `fortress-live-webrtc`. Configure mesh/WebRTC and MessagePack binary relay.
   The [WebRTC guide](signalfish-webrtc.md) documents the pinned local server
   build and browser prerequisites. Configure ICE servers for your deployment;
   loopback tests do not prove connectivity across public networks.
3. Select this scene as the main scene for a Web export. Use the compatibility renderer and
   a Web export without threads. Serve the export over HTTP on localhost for
   local development, or HTTPS for hosting. The SDK requires a `wss://` endpoint
   whenever the browser reports a secure context, including localhost HTTP
   in Chromium. A typical server route is `/v3/ws`. Configure WSS locally
   when testing the exported browser scene. The verified gameplay path uses
   exported browsers; native editor networking needs separately installed WebRTC support.
4. In the first browser, enter the WebSocket endpoint and player name, then
   press **Create room**. Copy the displayed room code.
5. In the second browser, enter the same endpoint, a player name and that code,
   then press **Join room**. The room is limited to two players.
6. Both players press **Ready**. The creator presses **Start** once both are
   ready. Network synchronization must complete before movement advances.
   Click outside text fields if a field still has keyboard focus.
7. Move with WASD or the arrow keys. The display reports your player number,
   frame, confirmed frame, stalls, latest event and active relay links.

## Leave and restart

**Leave / new room** detaches the fallback coordinator, direct and relay
adapters, membership adapter and SDK objects. To restart, both players leave;
the creator creates a fresh room and shares its new code. Join that fresh room,
ready again and start again. The scene does not restart inside the old room.

A connection failure, membership change, reconnect or terminal rollback error
stops the old game and asks players to leave and establish a fresh room. Automatic
SDK reconnect is disabled. Rejoining a server room cannot recover rollback
history or authorize a new session over old packet queues.

The application match identity is a domain-separated 16-byte SHA-256 prefix
of the fresh room UUID, sorted full player UUIDs and fixed game/config revision.
It is separate from the raw room UUID and each random transport-incarnation ID.
A new room changes that identity. The simulation uses the existing seeded,
fully snapshotted integer game; host clock and transport entropy never enter its
state. Keyboard input is retained across prediction or queue stalls until that
original frame is accepted.

## Verification

`tests/unit/test_online_example.gd` covers optional SDK scene loading, room
identity validation, real two-peer protocol startup over SDK transport doubles,
prediction stalls and held input recovery, caller-owned refusal retries and
terminal callback ordering. It runs through the ordinary headless test runner
with deterministic and fresh-process repeats. These injected tests establish
application behavior; exported browser evidence is a separate verification gate.

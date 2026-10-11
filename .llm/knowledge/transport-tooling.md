# Transport Development Facts

| Fact | Evidence | Verified |
| --- | --- | --- |
| Pinned SignalFish SDK browser clients refuse `ws://` when `window.isSecureContext` is true, including loopback HTTP pages. | SDK `signal_fish_client.gd:776,1629`; actual session-013 browser `protocol_error` reproduces the refusal. The [WebRTC guide](../../docs/signalfish-webrtc.md) describes WSS hosting. | 2026-10-11 |
| Godot 4.3's browser connection constructor initializes a default RTC connection; later initialization destroys its handle without closing that physical connection. | Engine `webrtc_peer_connection_js.cpp:96,130` and `library_godot_webrtc.js:316`; constructor-tracked [session 013](../../progress/session-013-webrtc.md) observes the orphan. Close before reinitializing. | 2026-10-11 |

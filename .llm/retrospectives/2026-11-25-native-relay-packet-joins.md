# Native relay packet joins

| Finding | Evidence | Action |
| --- | --- | --- |
| Equal payloads can represent different relay deliveries. | A mixed four-player room sent the same addressed packet twice, then readdressed the same native payload. The server stamped sequences 227, 228 and 229 at consecutive socket ordinals. The delayed page replayed 82 original WebSocket events and retained both stamped inbox acceptances in order. | Carry the v3 stamp through the staged SDK and relay queue. Compare the actual writer UUID and exact envelope digest. Use a controller barrier for cross-clock ordering. |
| A bounded stream can lose exact observations before the controller collects them. | The eight-player Godot 4.3 Firefox reporter joined its final quality report at sequence 3345 across raw arrival, SDK delivery and inbox acceptance. The latter was 2,006.9 ms before its expiry marker. The sender and server samples for that stamp had rotated out. | Keep omissions explicit. Retain #503 for the eight-player history requirement. |
| A packet body tag alone can inflate a complete-looking stream. | The focused control fed a truncated quality report and a MessagePack key with a leading BOM. Both forms could pass the initial observer checks. | Check the pinned body shape and exact field bytes. Keep the room scope immutable. |

The exported Chromium–Firefox control printed `relay:4 passed` on
Godot 4.3 and 4.7.2. Those runs compared 45 and 44 confirmed frames,
respectively, and recorded four clean leaves per room. The run that
reproduced the expiry reported no intentional leave.

The [browser integration guide](../skills/testing/references/browser-integration.md)
now records the occurrence and causality rules. The plan replaces the
packet join implementation item with the tracked retention requirement.

The existing [frozen-input guidance](../skills/testing/references/infrastructure.md)
also applies to local Gate runs. A concurrent source edit invalidated the
first Gate receipt with `failure: source_changed`.

State `findings-acted`.

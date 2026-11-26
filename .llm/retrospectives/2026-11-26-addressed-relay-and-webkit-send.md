# Addressed relay and WebKit sends

| Finding | Evidence | Action |
| --- | --- | --- |
| Matching packet bytes can occur on more than one browser channel and at several engine calls. | The wrong-channel-first and nested-unmapped controls failed before the route and reentry checks. A matching call with retained SDP still reached the DOM wrapper after the local connection reported closed. | Check the frozen reciprocal channel before consuming the receipt. Keep exact engine entry, wrapper call, return code and browser proof independent. |
| A private relay packet cannot consume the existing v3 broadcast sequence. | The real WebSocket regression interleaves both paths. A legacy bystander sees contiguous broadcast sequences while the addressed receiver sees the exact payload and separate receipt. | Negotiate distinct framing and keep the private receipt independent of broadcast gaps and departure watermarks. |
| Capability negotiation identifies the local socket. Each remote seat still needs its own live route evidence. | The two mixed-SDK browser controls took the ordinary broadcast path, while both complete-roster rooms used addressed delivery with zero recognized bystander copies. | Bind the choice to the complete frozen server roster and the relay lifetime. |
| A dynamic SDK call can change the relay's lifetime or socket. | The relay fixture replaced the socket during the adapter identity check after sampling its buffer. The stale ordering sent against the replacement. | Check the socket after the lifetime gate and account accepted bytes before reporting a later lifetime change. |
| A browser export validates the scripts inside the native addon archive. | The preview correctly rejected a stale runtime entry. A replacement archive with only the changed relay script kept the native Wasm bytes identical and passed the runtime inventory check. | Repack the frozen native artifact with the exact candidate runtime before running a preview. |
| Independent receipt streams can produce the same stamp and packet bytes. | A warmup sample disappeared when an addressed packet repeated a broadcast stamp and bytes. Removing the carrier from any stamped stage broke the six-stage regression. | Key every receipt join and warmup sample by carrier as well as stamp and bytes. |
| A pin update can leave an installation guide with a stale digest. | The guide's `sha256sum -c` failed on the verified SDK archive until its digest matched the manifest. | Run the documented checksum command when changing an archive URL. |
| The merge queue and nightly build and consume the pinned server independently. | The grouped build rejected its hard-coded previous source directory after the manifest moved. | Select the verified manifest source for the cache key, build, and browser witness. Check both workflows when moving the pin. |

The [browser integration guide](../skills/testing/references/browser-integration.md)
now records the recipient and call-order requirements. The plan drops the
completed #503 pointer and links the addressed-delivery dependency.

State `findings-acted`.

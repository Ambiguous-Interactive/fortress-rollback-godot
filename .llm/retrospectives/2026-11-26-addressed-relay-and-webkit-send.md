# Addressed relay and WebKit sends

| Finding | Evidence | Action |
| --- | --- | --- |
| Matching packet bytes can occur on more than one browser channel and at several engine calls. | The wrong-channel-first and nested-unmapped controls failed before the route and reentry checks. A matching call with retained SDP still reached the DOM wrapper after the local connection reported closed. | Check the frozen reciprocal channel before consuming the receipt. Keep exact engine entry, wrapper call, return code and browser proof independent. |
| A private relay packet cannot consume the existing v3 broadcast sequence. | The real WebSocket regression interleaves both paths. A legacy bystander sees contiguous broadcast sequences while the addressed receiver sees the exact payload and separate receipt. | Negotiate distinct framing and keep the private receipt independent of broadcast gaps and departure watermarks. |
| A browser export validates the scripts inside the native addon archive. | The preview correctly rejected a stale runtime entry. A replacement archive with only the changed relay script kept the native Wasm bytes identical and passed the runtime inventory check. | Repack the frozen native artifact with the exact candidate runtime before running a preview. |

The [browser integration guide](../skills/testing/references/browser-integration.md)
now records the recipient and call-order requirements. The plan drops the
completed #503 pointer and links the addressed-delivery dependency.

State `findings-acted`.

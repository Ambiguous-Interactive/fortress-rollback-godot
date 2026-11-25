# Same-link relay receipts

| Finding | Evidence | Action |
| --- | --- | --- |
| Unrelated link pressure and same-link pressure evict different records. | The original Firefox departure log preserved input 8368 and quality report 8369 at the recipient. Both corresponding ingress tails contained 128 newer records on that same directed link. | Add an eight-player control that preserves the old acceptance and drives 129 new physical sends per kind through the same link. |
| Deep receipts only need to expand the links under diagnosis. | The new Rust request test failed on the baseline when the publisher refused a valid selected generation. The browser test showed 12 omitted quality records where selected capture expected zero. | Keep 512 records for input and quality and publish the latest 128 during ordinary capture. Preserve original ordinals and report omissions at both depths. |
| Unaddressed broadcasts cost work before packet identity is checked. | Eight alternating Node samples each read 73,500 named MessagePack envelopes with 10,500 addressed records. Median time fell from 559 ms to 278 ms with the early recipient check. | Reject other recipients before hexadecimal identity decoding. Keep the full envelope and stamp checks for recorded packets. |
| Checking Python sources after normal imports leaves a stale-cache execution window. | The replay preflight process executed a timestamp-valid cached fixture on the baseline. It also retained a stale success receipt when a helper source was missing. | Invalidate receipts under the claim and compile tracked helper sources directly. Check the digest of the bytes compiled against the run inventory. |

The pinned library test binary reported `1460 passed; 0 failed; 4 ignored`.
Both exported Chromium pressure rooms printed `relay:8 passed`.
Each room recorded 129 blocked inputs, 129 blocked quality reports,
40 matching histories and eight clean leaves. The gates lasted 749 ms
on Godot 4.3 and 772 ms on Godot 4.7.2.

The [browser integration guide](../skills/testing/references/browser-integration.md)
now specifies the same-link control and limited receipt expansion. The
[migration guide](../../docs/native-backend-migration.md) documents the
local command. The
[ownership guide](../../docs/experiments/buffer-ownership.md) replaces the
previous cache-inspection procedure with source compilation and digest binding.

State `findings-acted`.

# Versioned coordinated-drop evidence

| Finding | Evidence | Action |
| --- | --- | --- |
| Version 6 reuses the inventory stage to announce the backfill cut. | All 17 captured schedules emitted and received an empty inventory with the chosen cut before the original donor backfill. Removing those reports left the genuine inventory records present. | Validate the announcement as its own shape and require the direct coordinator chronology. Keep empty reports out of participant inventory coverage. |
| The original donor can differ from the forwarding sender. | The captured source carried the same donor and range on 220 donor-to-coordinator and 144 coordinator-to-donor observations. | Check the plan identity separately from the addressed route. |
| The checksum header carries the sender connection across both routes. | The three seeded source endpoints emitted connection IDs 3955875504, 1183501648, and 748250720. Each used the same ID for its two recipients. | Bind headers to the seeded sender. Record the destination at the socket and require the complete directed frame series before and after the cut. |
| A generated Cargo manifest can reject a valid checkout path. | The Unicode checkout regression raised `TOMLDecodeError: Escaped character is not a Unicode scalar value` with the absolute path. | Generate a relative dependency path within the cache and parse it in the regression. |

The first real candidate comparison rejected `source emitted controls operation
schema`. The updated witness checks the participant digest, both epoch fields,
the original donor and range, and the post-cut checksum basis. It uses the
[coordinated-drop launcher](../../docs/oracle-p2p.md#scoped-coordinated-drop-history-comparison)
to verify the archive before building the observer.

The guide now distinguishes inventory evidence from cut announcements and
identifies which wire fields are attributable to the sender and recipient.
The previous retrospective's fixed-membership checksum rule still applies to
that corpus.

State `findings-acted`.

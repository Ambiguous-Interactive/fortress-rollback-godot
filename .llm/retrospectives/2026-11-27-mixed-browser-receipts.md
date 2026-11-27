# Mixed browser receive receipts

| Finding | Evidence | Action |
| --- | --- | --- |
| A page tag can identify more than one proxy socket. | The Chromium fixture had two local ports tagged for one page. The old join reported `observed` for the second socket, and the revised join reports `ambiguous`. | Require one tagged socket per frozen recipient, and restrict each observer to its engine's pages. |
| Browser shutdown can add observations after the original failure snapshot. | The proxy fixture received a second copy after freezing ordinal 1. A missing recheck left the exact match attributed to ordinal 1. The settled recheck found candidates 1 and 2. A proxy archive with an evicted candidate now also leaves the anchor unresolved. | Recheck complete proxy coverage after teardown. Preserve the old snapshot and link the supplemental observations to its acknowledged line. |
| A trace publication can miss its deadline after every player has left. | The Firefox 4.3 room on CPUs 0–2 captured forty original rows and eight successful Leave commands, with no expiry. The controller last read generation 2 before its three-second deadline. The server took 4.895 seconds to encode and flush generation 3 after snapshot collection. | Preserve the trace failure and its separate timing evidence. Keep the gameplay history and Leave receipts in the failure record. |

The drop-history comparison originally accepted a duplicate drain record with a
fresh counter and a source trace that omitted the delivered negotiation. It now
rejects both. The same setup with donor delivery enabled reaches the original
cut and canonical continuation. The [oracle validation guidance](../skills/testing/references/oracle-validation.md)
now binds retries to accepted publications, delivered negotiation and first terminal transitions.

Hosted review also found that same-poll Rust sends counted as distinct retries,
a missing positive COMMIT receipt passed, and a timeout could hide a committed
acknowledgement. The revised fixture rejects all three. The Godot recipient
moves from confirmed frame 4 to 5 when the recovery packets arrive. Its trace
now verifies the settled frontier through frame 5. The coordinator received
the donor's timeout ABORT and entered terminal state at 663000 µs. Its event
drained at 664000 µs. The updated guidance records both boundaries.

The [browser integration guidance](../skills/testing/references/browser-integration.md)
now requires the unique tagged socket and settled proxy check. It replaces
the earlier generic instruction about supplemental receipt attribution.

State `findings-acted`.

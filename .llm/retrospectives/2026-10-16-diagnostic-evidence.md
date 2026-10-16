# Retrospective: 2026-10-16 diagnostic evidence

## Work under review

Session 025 adds opt-in canonical mismatch evidence, completed-step notifications
and expanded browser work. Its user-facing tasks are #42, #40 and #39.
The source-receipt defect discovered during validation is tracked in #99.
The trigger is a new capability and a verification incident.

## Findings

| Finding | Evidence | Action |
| --- | --- | --- |
| Hashing repository sources only when publishing cannot prove which bytes an earlier staged export executed. | The #99 main-boundary regression accepted four changed source/copy/manifest/helper cases before repair. `/tmp/session025-source-red.log` records four failures. | Freeze source hashes before staging; validate copies and recheck before publication. |
| A later relocated copy can bypass an otherwise checked staging loop. | Fresh reviewer reproduced a changed `reference_checksum.gd` publishing success. `/tmp/relocated-copy-red.log` records the new failing control. | Relocate verified staged bytes, verify the destination, and check exact preload adaptation. |
| Presentation callbacks need the same recursion discipline as game callbacks. | Driver notification tests check completed rollback, expired views, failed callbacks, repair-only stalls and recursive advancement. Both engine pins pass. | Keep the driver guard held until every synchronous notification handler returns. Existing callback guidance and the public session guide own the contract. |
| Argument parsing can reject an attempt before invalidating its old success receipt. | #102 subprocess controls reproduce stale success after invalid browser choices, missing required options and unsupported mode combinations. Review also reproduces malformed valued help bypassing rejection. | Invalidate only the selected mode on parser errors; let argparse retain normal help semantics. Refine the existing receipt guidance in place. |

## Actions and verification

The [testing skill](../skills/testing/SKILL.md) now explicitly covers frozen hashes,
relocated bytes and end-only provenance errors. The old broad source-inventory
sentence was replaced at its existing home rather than duplicated.
Eight ownership receipt tests pass after the repair, including changed repository
sources, copied bytes, relocated bytes, manifest bytes and imported helpers.
The executable controls live in `scripts/reference/test_ownership_probes.py:55`;
`/tmp/relocated-copy-red.log` shows the relocated mutation escaping rejection and
`/tmp/relocated-copy-green.log` records all eight tests passing after repair.
A separate implementer repaired the review finding; independent re-review found
no remaining issue. Driver notification tests pass on both engine pins, and seven
native trace cases pass with a clean independent adversarial review.
Final source-bound browser receipts and shipping gates remain pending in
[the session log](../../progress/session-025-diagnostics-and-browsers.md).
Final exported native/Chromium ownership evidence passes all four records.
Firefox 4.3 clean/fault rooms pass on the reviewed runtime; full Firefox and
mixed-browser qualification is deferred to #104. Shipping gates remain pending.

## Prune ledger

Replaced the insufficiently specific source-inventory guidance in place.
No operational facts were retired; no duplicate skill or knowledge file was added.
Existing driver callback-guard guidance and shared-cache serialization guidance
already cover those findings, so neither is copied into another skill.
The testing skill is 299 lines; this replacement stays below its 300-line cap.
Harness regeneration, lint and self-tests verify the updated guidance.
The [transport knowledge](../knowledge/transport-tooling.md) records the scoped
Firefox/X11 scheduling fact after both WebGL and actual export observations.
The initial blank-page timing result was insufficient; the actual export still
failed until its windows were partly exposed. ICE needed a separate production
media-ID repair, without changing browser privacy settings. A fresh review then
found stale publication across reentrant extension callbacks; a revision fence
and public-signal regression repaired it. Firefox also throws when inspecting
SDP on closed connections; the throwing-getter regression and guarded collector
preserve the original failure evidence. This operational fact now lives beside
the X11 fact in transport knowledge. These lessons reinforce existing root-cause,
bounded-diagnostic and post-callback lifetime guidance rather than creating new skills.
The final installation check also exposed Firefox's empty `.parentlock` runtime
file. Its archive comparison and strict preseed/mutation controls live in the
session log and transport knowledge; executable and update changes remain hashed.
The #102 argument failure reinforces existing receipt invalidation guidance,
which now explicitly includes parse rejection and mode/help subprocess controls.
Viewport and FPS controls fail to repair the constrained-CPU Firefox witness.
The session log retains those falsified hypotheses. Reading the established
backlog tests also prevents treating a single-poll experiment as a shipping fix:
the existing eight-poll workload protects real bounded-queue progress.
The unproved adaptive prototype and experimental Firefox CI axes are deferred
to #104. The original Chromium, backlog and deadline gates remain unchanged;
the manual browser-pair launcher explicitly retains experimental status.

## Outcome

State: findings-acted. Broader replay tooling, browser lifecycle behavior and the
remaining release matrix stay with #42, #38 and #39. The cross-launcher receipt
sweep and remaining non-browser repairs are recorded in #103.

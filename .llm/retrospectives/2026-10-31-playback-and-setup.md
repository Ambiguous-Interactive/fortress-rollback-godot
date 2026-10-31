# Retrospective: playback navigation and online setup

## Work under review

Session 130 advances driver integration (#40), replay inspection (#45) and spectator controls (#47).
The changes add a replay timeline and bounded spectator catch-up, and fence canceled online setup.
New capabilities, a reproduced lifecycle defect and review corrections trigger this retrospective.

## Findings

| Finding | Evidence | Action |
| --- | --- | --- |
| Canceling from an SDK getter can precede core creation and still allow setup to continue. | `test_online_ownership.gd` setup controls fail the original implementation without engine errors; ordinary setup remains green. | Extend the existing composed-operation ownership guidance to setup getters and owner publication. |
| A drag-start pause alone does not own playback for the held interaction. | Fresh adversarial review crosses timeline dragging with P, refresh and release without movement. | Extend browser test guidance to held interactions crossed with shortcuts. |
| Test controls outside the live tree cannot establish actual Range signal routing. | Initial property-only timeline tests missed value-change delivery; deferred live scene and actual mouse click complete navigation. | Retain explicit signal tests for controller behavior and live GUI evidence for routing, following existing infrastructure guidance. |

The automated PR review also identified missing composed Match cancellation and detach-before-replacement controls.
The existing matrices were extended so inner-adapter success cannot substitute for caller cleanup coverage.
Global probes started before that review were retired when their input sources changed; their partial results do not qualify the final candidate.
Existing source-freeze guidance already covers this coordination, so it was reinforced rather than duplicated.

A later outside-diff review found that a getter-emitted plan could bypass an invalid lifetime observation.
Deferring only the adapter handler remained unsafe: the pinned SDK independently consumes the same signal and opens peers.
The transport guidance now requires checking downstream SDK consumers before buffering notifications.
Unsafe reentry is refused before SDK consumption; no private handler or synthetic notification is used.

## Verification and limits

The new timeline capability first fails on the missing control, then passes the focused suite on both engine pins.
The independent canonical-state test also refuses a corrupt prefix at its owning frame.
Spectator tests compare changing original history and preserve viewing policy and host progress.
Online setup tests cover getter cancellation, nested setup and transport setup ownership.
Machine-local session logs retain exact commands, red/green receipts and final candidate delivery evidence.
Broader issue acceptance, source parity and release qualification remain open.

## Prune ledger

- Updated existing owning skills; no new overlapping skill was created.
- Existing callback and GUI-focus guidance remains correct and is retained.
- Existing source-freeze guidance already covers concurrent verification; no duplicate entry was added.
- No obsolete invariant or knowledge fact was identified for removal.

## Outcome

Retro: findings-acted

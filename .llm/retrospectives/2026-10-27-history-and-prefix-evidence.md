# Retrospective: 2026-10-27 history and prefix evidence

## Work under review

- Scope: peer-drop donor publication, captured replay prefixes and local spectator guidance.
- Trigger: two reproduced correctness gaps and misleading playback feedback.
- Evidence: baseline failures, paired positive controls, focused native tests and independent reviews.
  Exact commands and machine-local receipts are recorded in `progress/session-094-gameplay-correctness.md`.

## Findings

| Finding | Evidence | Action |
| --- | --- | --- |
| Independent retry clocks do not prevent a global phase gate from starving healthy data. | `peer_drop_transfer.gd:90` returned after every incomplete plan round; the new plan-fairness regression observed zero healthy chunks. | Permit data only for destinations that accepted the current plan, while refused plans keep retrying. |
| A phase fix needs both retry equality and lost-data controls. | Fresh review reproduced zero data at equality and no healthy retransmission after a lost chunk while a foreign plan stayed blocked. | Give completed donor rounds per-link deadlines and yield partial plan rounds to healthy data. |
| A trimmed recording can already contain valid evidence for its new endpoint. | `replay.gd:420` now selects the original pre-input checksum at the prefix boundary; callback and expert tests detect final-only mutation. | Preserve existing v6 evidence without borrowing later checksums or promoting historical formats. |
| No immediately eligible steps does not imply playback has stalled. | The first spectator label candidate called healthy caught-up playback BUFFERING; the positive WATCHING control rejected it. | Restrict the startup label to the initial displayed frame and preserve terminal precedence. |

## Actions taken

Extended the existing [transport guidance](../skills/networking-transport/SKILL.md)
at its replay ownership and publication fairness paragraphs. No new skill or duplicate
checklist was created. Added exact new cases and required preload dependencies to
the existing native/browser ownership inventory. Refreshed and inspected the
rendered spectator example image.

## Prune ledger

- Replaced the incomplete fairness paragraph at its canonical home.
- Retained separate per-link retry deadlines, bounded work and plan-before-data ordering.
- Preserved legacy replay layout and missing-evidence limits.
- Retained broader source/live acceptance in issues 188, 45, 47 and 131.
- Reflowed nearby transport guidance to keep the skill below its 300-line cap.

## Verification and limits

The new regressions fail at the original source and paired controls pass. Focused
replay tests pass on both engine pins; focused spectator and drop suites pass on
current Godot. Fresh independent reviews cover each change. Full native/browser,
source-width, harness and current-head CI evidence belongs to the session delivery
log. This scoped repair does not establish complete drop, replay or live spectator parity.

## Outcome

Retro: findings-acted

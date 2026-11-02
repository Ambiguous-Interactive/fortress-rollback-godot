# Retrospective: visible match controls and faster selection

## Work under review

Session 143 adds pointer access to online delay and spectator host-loss actions,
status-only replay navigation, and faster changed-suite selection.
New capabilities trigger the retrospective loop.

## Findings

| Finding | Evidence | Action |
| --- | --- | --- |
| Repeated class-name regex searches dominated suite selection. | Four real changed paths took 1.758–2.179 seconds before, 0.127–0.264 after; selected suites were identical. | Index complete word tokens once per file in `scripts/changed_suites.py`. |
| Pointer actions can share existing controller lifetime gates. | Existing `delay_actions` and `host_loss_control` cases exercise the new buttons alongside keyboard paths and terminal/request boundaries. | Reuse handlers and extend owning tests instead of adding controller APIs. |
| A plausible replay metadata defect was already excluded by the format contract. | `Replay.valid_text()` accepts printable ASCII; inspection did not establish the proposed control-character failure. | Discard the hypothesis and implement useful status navigation instead. |
| Concurrent source edits invalidate native qualification. | The online minimum-engine attempt reported `source_changed` despite passing assertions. | Keep that attempt disqualified and run final qualification after a shared source freeze. |
| Button-signal tests did not cover live GUI focus traversal. | A real mouse click followed by Up presses reached a read-only text field and suppressed movement. | Release focus after accepted gameplay actions and extend the existing deferred scene-input witness. |

## Curation and pruning

The testing infrastructure reference already requires coordinated source freezes,
matching native/Web inventories and real UI routing checks. The debugging skill
already requires evidence before a fix. Those instructions remain applicable;
no duplicate skill or knowledge entry is needed.

Automatic review found the focus defect after initial independent review. The
existing live-scene witness now exercises mouse, arrow and keyboard activation;
signal-only tests remain useful for readiness but cannot establish routing.

The selector documentation now explains complete-token matching. CI path filters
now include its native runner helpers. Existing conservative selection, renamed
class, directory-reference and unknown-change cases remain required.

No obsolete guidance was identified for retirement. Browser timing claims in
`docs/reference/jobs.md` remain scoped: local selector speed does not establish
the warm browser job targets in issues #148 and #164.

## Outcome

State: `findings-acted`.
Broader replay, spectator, driver and browser-release acceptance remains open.
Final test, review and delivery evidence belongs in the session log and issues.

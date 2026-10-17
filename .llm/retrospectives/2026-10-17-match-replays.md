# Retrospective: 2026-10-17 match replays

## Work under review

Session 027 adds match recording and replay playback (#45) and triages the
eight-player Firefox CI failure (#104). The [session log](../../progress/session-027-match-replays.md)
owns commands, mutation results and delivery evidence.

## Findings

| Finding | Evidence | Action |
| --- | --- | --- |
| A failing browser CI job looked player-facing, but each page reported visible, focused scheduling at 8–10 frames per second. | `.cache/tests/session025-ci-artifacts/clean-failures-summary.json` peer `scheduling` fields. | Read per-page scheduling evidence before ranking a browser failure by gameplay impact. #104 keeps its acceptance. |
| The first replay script failed to compile on 4.3: a packed-array constant and a self-referencing `class_name`. | First focused run stderr: "isn't a constant expression" and "Identifier not found: FortressReplay". | Added the headless `class_name` and constant rules to the [GDScript style skill](../skills/gdscript-style/SKILL.md). |
| One planned mutation (record after discard) was equivalent, not a defect. | It passes because confirmation never trails the discard floor. | Kept the invariant in the code comment and replaced the control with recording before confirmation, which fails. |
| Mutation copies outside Git fail before running tests. | The runner calls `git rev-parse HEAD`; the first mutation receipts report exit 128. | Initialise Git in scratch copies; the testing guidance already requires a valid receipt. |

## Prune ledger

No guidance became stale. The integration guide's "replays are not available"
statement is replaced by the new section and the Rust mapping rows.

## Outcome

- State: `findings-acted`.
- Follow-ups: #45 keeps cross-build replay, a format golden and seek support; #104 is unchanged.

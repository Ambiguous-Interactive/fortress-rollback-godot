# Retrospective: 2026-10-10 representation and shipping

## Work Under Review

Scope: R1/R2 representation experiments, corrected checksum sample, four-surface
feedback scanner, standing squash-merge guidance, user copy and 180 source width.
Trigger: new skills/workflow, large source change, external sibling evidence and
fresh-review corrections. Evidence is in
[session 003](../../progress/session-003-representation-and-shipping.md) and the
[integer](../../docs/experiments/integer-encoding.md) and
[ownership](../../docs/experiments/buffer-ownership.md) experiments.

## Findings

| Finding | Evidence | Durable home |
| --- | --- | --- |
| One feedback endpoint cannot establish no pending feedback | Sibling four-surface procedures; PR54 live scan; scanner 16 controls | [ship-session](../skills/ship-session/SKILL.md) |
| Valid aggregate counts can hide duplicate IDs or malformed records | Fresh scanner review; red mutation controls, then 16 passing methods | `scripts/github/pr_feedback.py` + tests |
| A nested mutation outside the saved payload proves no snapshot isolation | R2 review; retained-object mutant expected 1 versus actual 9 after repair | Ownership experiment and its restored-state assertion |
| Bool is an integer subtype in Python, so `count > 0` accepts true | R2 receipt review; bool and missing-errors controls reject after repair | Receipt schema mutation table |
| Packed-array boundaries have different ownership semantics | Both pinned engines/native-Web: assignment aliases; StreamPeerBuffer getter/setter/data copy | [determinism](../skills/determinism/SKILL.md) |
| Algorithm labels do not verify constants | Original FNV sample fails empty known answer; corrected sample matches eight independent Rust vectors | Integer experiment, checksum sample and issue 56 |
| Godot excludes hidden instruction directories from Web resources | Initial checksum export failed; visible byte-identical sample copy passes matrix | Ownership experiment reproduction notes |

## Actions and Verification

Updated existing determinism and testing guidance rather than creating overlapping
runtime skills. Added narrowly scoped user-copy and ship-session skills, sourced
from exact sibling revisions. Context/GOAL/PLAN link their canonical owners.

Meaningful new controls preceded scanner repairs and receipt-schema repairs.
Source-width controls demonstrate 180/181 and new hook coverage. R1 checks an
independent Rust oracle; R2 checks exact saved/restored payloads and expiring views.
The combined minimum/current native/Web receipt validates eight cases twice,
520 assertions per repetition, exact alias-negative diagnostics and byte equality.
Fresh review rechecks accept the repaired scanner and ownership paths; R1 review
independently executes native suites and checks published FNV answers.

`make llm-index lint-source lint-llm test-llm test-reference` passes: 90 tooling
tests, 25 offline reference methods passed and two engine methods skipped, and zero
source-width violations. Explicit six-method runner controls and fresh-process
wrappers pass on each pinned editor. Local environment acceptance passes 28/0.

## Prune Ledger

- Replaced stale bootstrap-era context wording with the actual foundation state.
- Scoped the Rust exclusion to shipped runtime; the independent oracle is tooling.
- Replaced testing's future-CI wording with current runner/reference checks.
- Corrected the mislabeled checksum at its source and guarded the replacement.
- Kept negotiated 16-byte checksums distinct from the eight-byte example.
- Kept copying rules in determinism and shipping details in one owning skill.
- Considered broader bootstrap networking/rollback guidance; full semantic audit
  remains issue 13's scope and was not claimed by representation experiments.

## Outcome

State: `findings-acted`.
Follow-ups: R3 benchmarks and production core/transport tasks remain in the
existing GitHub roadmap; no new performance or full-parity claim is made.

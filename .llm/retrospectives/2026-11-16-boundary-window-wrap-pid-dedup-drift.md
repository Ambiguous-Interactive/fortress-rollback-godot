# Retrospective: `2026-11-16 boundary-window wrap, owned-pid dedup, M1 drift classifier`

## Work Under Review

- Scope: one session PR (#382) addressing three open issues — the
  window-eight wrap-flood corpus case (#34/#59), the owned-process
  survivor-report dedup that fixes the #381 load flake, and the M1 upstream
  drift classifier core (#51). Session log:
  `progress/session-190-wrap-window8-test-stability-drift.md`.
- Trigger: session goal (address open issues by gameplay impact; one PR;
  under two hours).
- Evidence base: wrap-corpus receipts on both pinned engines at the final
  head (nine cases, twice per side, raw compression validation, 18 process
  controls per run), the #381 load reproduction (5/15 failing standalone
  iterations under a 32-spinner load, 15/15 after the fix, mutant control),
  startup-latency measurement ruling out the 2-second budgets (p90 16 ms),
  the drift classifier's data-driven suite and real-tree smoke runs,
  `make gate`, `make test-reference` 39/39, `make test-oracle` 18/18.

## Findings

| # | Finding | Type | Evidence |
| --- | --- | --- | --- |
| 1 | The mid-run-edit evidence invalidation happened AGAIN despite being recorded in the previous session's retro (finding 1 of `2026-11-16-wrap-flood-default-ring.md`): creating `scripts/reference/drift.py` while both wrap launchers ran failed both receipts at "evidence identity changed: local source inventory" and cost both engines a full re-run. A lesson that lives only in a retro artifact does not reach the moment of failure; the durable fix is a top-level rule in the testing skill's Rules list, which is the place agents actually consult before starting suites. | process (repeat finding — second occurrence, system-fixed this time) | session-189 retro finding 1; both session-190 first-pass receipts discarded; rule 8 added to `.llm/skills/testing/SKILL.md` |
| 2 | The #381 incident's recorded hint ("process-group timing") was wrong about the mechanism: the actual cause was duplicate survivor attribution when both ownership sweeps name one dying pid, not timing budgets. Measurement beat the hint — 40 cold launches of the exact deadline child shape under the same 32-spinner load peaked at 43 ms, ruling out the 2-second budgets in one experiment and pointing at the only assertion that could produce the observed unpack error. The issue text's own two hypotheses (budget vs output race) were both wrong; the third possibility (sweep-merge attribution) was found by reading the assertion that failed, not by instrumenting broadly. | fact (classification method) | `.cache/scratch/session190/owned-failure-*.log`; `startup_latency.py` output; `test_owned_process.py:98` unpack |
| 3 | Reproducing a once-per-full-run flake standalone under synthetic load took one design iteration: looping the file under 32 spinners produced 5 failures in 15 iterations within ~3 minutes, where the incident had appeared once across a multi-minute suite run. Looping the suspect file under representative load is far more efficient than looping the whole suite when the failure signature (the specific assertion) is known from a captured log. | technique (worked well) | reproduction command + counts in the session log |
| 4 | The stale docs claim ("Those issue requirements remain open") survived four sessions after #61 closed because docs record what a section does NOT prove and nothing revisits closed-issue pointers. The reconciliation was found by grepping the docs for open-requirements phrasing against the closed-issue state, not by any review gate. Doc claims about other issues' state have no automated drift check. | defect (doc rot, now reconciled) | `docs/oracle-p2p.md` asymmetric-wrap section before/after this PR |
| 5 | The wrap harness's window parameterization was a three-line-per-file change because session 189 kept the profile table as the single source of truth (fixture loader, evidence checks and tests all read `PROFILES`). Adding a dimension to the table propagated through every gate without any fixture format change. | design (in the same PR) | `p2p_wrap.py` PROFILES/window; `wrap_fixture` window check; `test_wrap_fixture_inventory` |

## Actions Taken

| # | Action | Where it landed | Verified by |
| --- | --- | --- | --- |
| 1 | Rule 8 ("freeze the tree for the whole duration of an evidence run") added to the testing skill's Rules list — the system fix for the repeat finding. | `.llm/skills/testing/SKILL.md` | `make lint-llm`; this retro's finding 1 cites both occurrences |
| 2 | #381 fixed in production code with the dedup helper at all four sweep consumers, data-driven unit test, mutant control, and 15/15 loaded green; issue closed with the full evidence trail. | `scripts/reference/owned_process.py`, `test_owned_process.py`, issue #381 | mutant detected; loaded loop green; suite green |
| 3 | The window-eight wrap point delivered with per-case window plumbing and the `--only` regeneration path; docs and PLAN updated; stale open-requirements paragraph reconciled. | `scripts/oracle/p2p_wrap*.py`, `p2p_launch.py`, fixtures, `docs/oracle-p2p.md`, `PLAN.md` | both pins' nine-case receipts at the final head |
| 4 | M1 classifier core delivered with the issue's full synthetic shape matrix; remaining scope named on the issue (pin-advancement integration, M2 wiring). | `scripts/reference/drift.py`, `test_drift.py`, docs/reference/README.md, PLAN.md, issue #51 | 10-case suite green; real-tree smoke |

## Nothing Pruned

No prior guidance became stale. The #307 review-availability policy, the
ship-session queue flow and the harness caps ran unchanged. Session 189's
retro artifact stays (its findings 1 and 6 are now respectively system-fixed
by rule 8 and resolved by the #381 fix; both facts are recorded here rather
than editing the historical artifact).

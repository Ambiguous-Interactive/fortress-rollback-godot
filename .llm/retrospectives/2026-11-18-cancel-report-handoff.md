# Retrospective: `2026-11-18 cancel-report-handoff`

## Work Under Review

- Scope: `scripts/reference/owned_process.py` + its suite — the #399
  cancel-versus-report redesign (single consumption point `absorb()`,
  `emit()`/`settle()` handoff with an append door, recycled-group boundary
  with a token tiebreak, sweep reorder). Squash merged as e293c4a (#400);
  3 files changed, 664 insertions, 137 deletions.
- Trigger: large change; corrections (adversarial review round 1 found two
  blocking defects); incident (the first design could strand a live
  carrier past its pin window).
- Evidence base: owned_process 52/52; reference suite 42 files 0 failed;
  harness 245 tests OK; `make lint-source` clean; the forced-schedule
  driver (.cache/redcheck/window_driver.py) run against both
  implementations; the round-1 and round-2 review reports (session log
  `progress/session-200-cancel-report-windows.md`).

## Findings

| # | Finding | Type | Evidence |
| --- | --- | --- | --- |
| 1 | A concurrency seam test binds only if the forced schedule fails on the pre-fix implementation; the first committed window test passed vacuously on the old code because its mock wrapper was missing, and only a red run against the old module exposed it. | technique | `test_a_cancel_starting_at_the_log_write_still_names_its_carrier` failed 3/3 on `3610466a`'s module and passed 3/3 on the fix; the pre-corrected version logged `DBG scans=0` with both pids named |
| 2 | Holding a coordination lock across a log write reordered a cancel thread past its `unregister()` window: the flip then read a cleared pin and the stranded tree stopped nothing. Locks that gate identity/lifecycle transitions must not span I/O; serialize the I/O on a dedicated lock. | fact | forced-schedule driver against the first design: `carrier: alive`, `cancel named: []`; fixed design: `cancel named: [carrier]`, name appended, 3/3 |
| 3 | `Path.write_text` truncates, so a mixed truncate+append log protocol loses the appended line whenever the append lands inside the write; a hostile sink must also be able to raise anything. | fact | round-1 review finding 3 (0/25000 under the GIL, structurally real) and finding 5; fixed by `_log_lock` spanning close+write and `except Exception` in `_append_sightings` |
| 4 | Post-reap `/proc` group scans cannot use a pidfd (signals to a reaped leader fail), so recycled-id defense reduces to a starttime boundary plus a token tiebreak; the irreducible residual (token-scrubbed post-boundary forks, and the death-to-sample sliver) is the #290 cgroup class. | fact | round-1 finding 2's strand probe (clean return, grandchild alive) vs the post-death boundary probe (`EscapedDescendants`, killed); the OpenAI review thread on #400 and the recorded disposition reply |
| 5 | Worked well: forcing exact interleavings (gated identities, call-counted seams, log-sink triggers) against both implementations found a design regression the code review did not. Reinforce: build the forced-schedule driver before the review round, not after. | technique | the driver caught the lock-spanning-write strand before round 1; the reviewer independently confirmed the window was real |

## Actions Taken

| # | Action | Where it landed | Verified by |
| --- | --- | --- | --- |
| 1 | Recorded the forced-schedule red-green rule and the two-writer log-serialization rule as development facts | `.llm/knowledge/transport-tooling.md` | `make lint-llm` |
| 2 | Module docstrings already carry the lock-order and residual-hole contracts (no separate skill — `grep` found no non-shadowing home) | `scripts/reference/owned_process.py` docstrings | round-2 review verified findings 3/4 |
| 3 | This artifact | `.llm/retrospectives/2026-11-18-cancel-report-handoff.md` | committed with the session close |

## Prune Ledger

- Retired / merged / fixed at source: none — considered: the
  `owned_process` module docstring is the authoritative protocol record,
  so no knowledge entry duplicates it; `grep -ri owned_process .llm/`
  found no stale claim to retire.
- Verify-on-touch: the harness and reference suites were re-run after the
  knowledge write (`make test-llm`, parallel_unittests) — green.

## Outcome

- State: `findings-acted`
- Follow-ups: #290 (cgroup-backed ownership) owns the recycle-proof
  identity; the settle() branch is defensive-only on the unpinned tails
  (recorded, kept as insurance); #249 stays blocked on the next real
  install failure; #276 stays with the repository owner.

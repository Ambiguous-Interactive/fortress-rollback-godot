# Retrospective: `2026-11-19 leader pin`

## Work Under Review

- Scope: session 202's PR #405 — issue #404 (recycle-proof post-reap
  ownership identity for `scripts/reference/owned_process.py`), five
  commits (`035fb56` pin + cancel coverage, `2c5bde0` recheck strand
  bias, `55df1c1` adversarial round 1 fixes, `66e480b` starttime
  identity rechecks, `588a626` fallback removal, `6f6ca7c` finish
  cleanup guarantee), plus the issue work: #404 implemented,
  #387/#388/#389 drift verified, #249/#276 re-verified, #406 opened
  for two stale worktrees.
- Trigger: large change; adversarial review round with two blockers
  (one refuting the design's kernel premise), three bot review rounds
  across four pushed heads, one self-caught flake with a production
  root cause.

## Findings

| # | Finding | Type | Evidence |
| --- | --- | --- | --- |
| 1 | A plausible kernel mental model ("a pidfd reference keeps the numeric id allocated") survived two design passes and a committed churn witness — and was wrong. `free_pid` runs at the last *task-link* detach; a pidfd keeps the `struct pid` memory alive but the idr entry goes back to the allocator. Only a churn across a FULL pid cycle (~99k forks on `pid_max=99999`) refuted it; the 120-fork sample could never fail and looked like evidence. Measure recycling across the whole cycle, never a sample bounded far below wrap. | fact + technique | adversarial round 1 measurement (id reissued at fork ≈98987 with the pin held open, group empty, leader reaped); the vacuous witness deleted; corrected entry in [transport-tooling knowledge](../knowledge/transport-tooling.md) |
| 2 | The design consequence: a pidfd is a recycle-proof *signal* identity (`pidfd_send_signal` + `PIDFD_SIGNAL_PROCESS_GROUP` through the pinned struct pid, valid through alive/zombie/reaped leaders — all measured), but numeric group scans must keep their exit-boundary + token guards in every leader state. The issue's own acceptance line ("the filters may stay as defense in depth") turned out to be load-bearing, not optional. | fact | `owned_process.py` `_post_exit_group_sweep`/`finish` boundary restoration; `group_members` docstring; #404 acceptance text |
| 3 | Kill-time re-verification trades windows indefinitely: a token recheck strands scrubbed carriers, an empty-env bias passes recycled pids, a pgrp recheck passes recycled group members. The convergent fix is the stable immutable identity — scanned `/proc` starttime compared after a kill-time pin — which closes scrub-escape, recycled-pid misdirect and pinless recycled-member windows at once; the irreducible residual (same-tick recycle inside the scan-read→pin microseconds) is named in the docstring and owned by #404's cgroup work. Stop at the named residual; further recheck schemes just rotate the window. | technique | three bot rounds each found one window (`test_owned_process.py` inline threads, all replied); `_identity_check`; `test_the_identity_recheck_keeps_carriers_and_skips_recycled_pids` |
| 4 | Strictness can strand: removing a numeric fallback "for safety" left `finish()`'s grace path with no kill at all on flag-4-less kernels, so a SIGTERM-ignoring host raised TimeoutExpired out of finish and skipped the sweeps. Every fallback you remove needs its replacement stop verified on the same path, with a red test (SIGTERM-ignoring host + forced flag-4 failure raised TimeoutExpired pre-fix). | fact | OpenAI review on `588a626`; `test_finish_stops_a_sigterm_ignoring_host_when_the_group_signal_fails` red pre-fix, green post-fix |
| 5 | A timing shift in unrelated code exposed a pre-existing production race (the plain-timeout branch's single `poll()` racing kill delivery, leaving the killed child an unreapable zombie of the test process). The fix belongs in production (wait the reap, bounded), not in the test's tolerance. | fact | `test_a_cancel_landing_mid_sweep_of_the_deadline_keeps_every_name` failure in 1 of ~5 suite runs; fixed by `process.wait(timeout=10)` in the deadline branch |
| 6 | The 2026-11-18 record "the pidfd probe fails on zombies" was wrong (re-run: probe succeeds on zombies on 6.12.76); the `_leader_reaped` machinery built on it is removed entirely because the pin makes leader-liveness gates unnecessary. Knowledge entries were corrected at source per the lifecycle contract, not contradicted by a second entry. | correction | `.cache/redcheck/pin_reap_matrix.py` re-run; [transport-tooling knowledge](../knowledge/transport-tooling.md) CORRECTED entry; supersession noted in the CHANGELOG |
| 7 | Environment limits must be measured, not assumed, when an issue's acceptance offers options: cgroup delegation (read-only `/sys/fs/cgroup`, non-root) and pid namespaces (`unshare` without CAP_SYS_ADMIN) were both impossible here, so the pidfd half was implemented with the unprivileged equivalent of the hostile test committed, and the incapable-environment demand kept open in the issue with the measured evidence. | technique | #404 comment + PR #405 description; `pin_reap_matrix.py` |
| 8 | Stale worktrees from old sessions hold real unmerged work (13-commit spectator stack from 2026-11-05; an agent commit from 2026-10-18). A session sweep should `git worktree list` + ancestor-check them and open a tracked issue rather than blind-merge or silent-delete. | technique | new issue #406 with both leftovers, commit lists and adjudication criteria |

## Verification record

- owned_process 68/68 across repeated runs at the final head
  (reviewer's own 6-iteration loop: 6×OK); signalfish probe 22/22;
  spectator browser 16/16; oracle launch 14/14; `make test-changed`
  (full GDScript unit inventory) passed; `make test-llm` green;
  `make lint-source` 552 files, 0 violations.
- Adversarial re-review verdict at `588a626`: merge-ready, all prior
  findings resolved; the two follow-ups it and the OpenAI bot raised
  afterward (finish cleanup bypass, interrupt boundary symmetry) are
  the final commit `6f6ca7c`.
- Red-green ledger: cancel-after-reap (member stranded pre-fix),
  run-pin lifecycle, kill-time identity, boundary seam, fallback
  gates, finish-under-failed-flag-4 (TimeoutExpired pre-fix), each
  verified red on the old module before trusting green.

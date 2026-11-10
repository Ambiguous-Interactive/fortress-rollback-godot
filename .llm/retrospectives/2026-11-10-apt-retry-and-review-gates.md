# Session 170 retrospective findings (acted)

Date: 2026-11-10. Artifact: progress/session-170-apt-retry-review-policy.md.
Merge: `9db1b41` (#350). Issues addressed: #349 (repair delivered, real-recurrence
acceptance pending), #253 and #256 (upstream resolution verified and recorded),
#307 (delivery-gate policy documented).

## Finding 1 — gating a retry wrapper on the caller's exit code missed the real incident

The first draft retried only when the wrapped command exited 100. A fresh
adversarial sub-agent reproduced, from the pinned Playwright source, that
`playwright install-deps` runs apt itself and converts apt's exit 100 into its
own exit 1 (`packages/playwright-core/src/cli/program.ts` → `processExit(1)`).
The motivating #349 incident was exactly that path, so four of the eight wrapped
sites would never have retried. **Lesson: when wrapping a tool that invokes a
subsystem, gate recovery on evidence in the captured log (the failing
subsystem's own diagnostic), not on the outer tool's exit code; outer wrappers
remap exit codes.** A second adversarial pass then proved from the apt binaries
that the log-signature gate has no false-positive class (`libapt-private`
carries the line; `libapt-pkg`'s update path uses a disjoint string).

## Finding 2 — the bot review and the adversarial sub-agent converged on the same defect

CodeRabbit's Major finding (process-substitution tee race) and its playwright
exit-mapping finding independently matched the sub-agent's C1 and the second
sub-agent's M1 on the same small diff. Both reviewers also left findings the
other lacked (unlink-outside-subtest vs. exit-code gate). **Lesson (confirms
session 168): run the bot review and a fresh-context review on every pushed
head; treat convergence as confirmation and divergence as coverage.**

## Finding 3 — one issue's upstream prerequisite was already satisfied upstream

#253 demanded filing an upstream report, and session planning had assumed the
report would be this session's deliverable. Checking upstream first found
wallstop/fortress-rollback#380 fixed by #381 the same day. **Lesson: before
executing a "report upstream" acceptance item, search the upstream tracker for
the defect; record the resolution with commit and regression-test citations,
and keep the local pin policy (#53) unchanged until this repository executes
the fixed revision.**

## Process observations

- The first fixture-subtest iteration exposed a script bug before CI did
  (exit-status capture under `if !`); the red-green loop on the fake
  acquisition command stayed local and fast.
- Three CI rounds ran (initial head, gate fix, test hardening). Each round was
  a real pushed review fix; the session finished within the two-hour budget.
- Thread resolution was done with authenticated GraphQL mutations rather than
  the bot's `@coderabbitai approve` command, which GOAL.md forbids; the bot
  approved automatically after the threads were resolved.

# Retrospective: `2026-11-19 cgroup containment`

## Work Under Review

- Scope: session 205's PR #415 — issue #411 (cgroup membership
  containment for the owned-process sweeps), three commits (`e91fcff`
  claim/sweep/release + twelve witnesses, `af890b4` adversarial round
  fixes, `01cf2ca` CHANGELOG wording, `b031706` bot-review round
  fixes), plus the issue work: #48/#166 acceptance verified and their
  shared remainder decomposed into #414, fresh upstream evidence on
  #131 (Dependency Audit cleared) and #249.
- Trigger: large change; one fresh-context adversarial round with a
  demonstrated CRITICAL, one re-review round, and three convergent bot
  review rounds across four pushed heads.

## Findings

| # | Finding | Type | Evidence |
| --- | --- | --- | --- |
| 1 | A membership snapshot is not a kill authorization. `terminate_cgroup` initially killed each scanned pid behind the scanned starttime identity — but the identity check proves "the pinned process is the process the scan read", not "the scan's process is the process the kernel listed". A member that exits between the leaf read and the stat read hands its recycled pid a valid-looking identity, and the sweep kills a stranger. OpenAI and CodeRabbit converged on the same hole independently hours after the human adversarial round (which missed it too). The fix ties the authorization to the kernel's record at kill time: pin first, re-read the leaf's `cgroup.procs`, signal only while the pinned pid is still listed. Scan-time snapshots authorize nothing; only a record read under the pin does. | fact + technique | OpenAI inline `4634520067` + CodeRabbit outside-diff minor, both on different heads; `_leaf_member_check`; `test_terminate_cgroup_skips_a_target_the_leaf_no_longer_lists` |
| 2 | A seam test that cannot reach the seam it names proves nothing and still passes. The failed-placement witness pointed its mountinfo at `/sys/fs/cgroup`, so the claim failed at the real read-only mkdir and the partial-leaf teardown it exists to pin never ran — green, vacuous. A seam test must assert the seam was reached (here: the placement write's exact path) before asserting the consequence. | technique | CodeRabbit inline `4634322939`; `test_a_failed_claim_removes_its_partial_leaf` now records the write attempt |
| 3 | The two human-verified claims of the session both came from reading concurrency, not testing it: the release-gap hazard (a cancel sweeping after the leaf is dropped) is unreachable because `unregister()` clears the handle's process before the tail runs and `absorb()` waits out every earlier flip until its sweeps finish. Adjudicating a reviewer's mechanism by reading the synchronization order — and diffing the disputed path against main (`byte-identical except the release line`) — kept the fix round at documentation instead of a wrong "fix" that added a tombstone. Round-2's independent verification of the dispute is what made declining safe. | technique | adversarial round-1 finding 2 vs the round-2 re-review verdict; `_release_cgroup` docstring |
| 4 | The fake-pid kill exposure (CRITICAL) was caught by an adversarial reviewer, not by the suite: the tests killing pid 90 through the real path stay green whether pid 90 is dead, absent, or a live host process — the assertion cannot see the difference. Any test whose inputs overlap the real pid space needs its side effects stubbed and its stub recorded (the recording stub also strengthened the membership pin). Environment-hostile tests must be killed-stub, not kill-safe-by-luck. | fact | adversarial round 1, demonstrated live (`live unrelated process was killed: True`); af890b4 stubs |
| 5 | Delegated cgroup subtrees need the mount's root field, not just its mount point: `/proc/self/cgroup` names paths from the namespace root while a bind-mounted subtree shows that root at the mount point, so appending the full path to the mount point fails the mkdir and silently forces the documented fallback — containment lost on exactly the hosts (systemd user slices) that can grant it. Map the path relative to the mount root; refuse when the cgroup is outside it. | fact | OpenAI inline `4634219132`; `_relative_leaf_base` + delegated witnesses |
| 6 | A stranded leaf is not "inert empty": the dominant non-removable case is a leaf still holding the members the sweeps could not stop (kernel EBUSY). The same wrong phrase survived in a docstring, the CHANGELOG and the PR body after two review rounds — one surface was missed each time. When a claim is corrected, sweep every surface that repeated it (docstring, CHANGELOG, PR body, knowledge row) in the same commit. | technique | round-2 MINOR; `01cf2ca`; the PR-body sweep in the bot round |
| 7 | Bot review value: the three bot rounds each contributed at least one finding the human round missed (#1's recycled-pid kill, #5's mount mapping, #2's vacuous test), while their release-gap findings repeated a mechanism a human reviewer had already disproven. Adjudicate every bot finding against the code on its own merits — accept by mechanism, decline by proof — never by author. | technique | the bot-round disposition table in `progress/session-205-cgroup-containment.md` |

## Verification record

- owned_process suite 101/101 at `b031706` (98 base + the review
  additions); `make test-reference` 42/42 files; `make lint-source`
  552 files, 0 violations.
- Red-green ledger: the twelve containment witnesses error on the
  pre-fix module (`progress/red-cgroup-containment.log`); the
  forced-schedule regression asserts both sides of the schedule on one
  tree; the kill-time recheck witness drives a recycled pid end to end
  (neither signaled nor named).
- Review of record: adversarial round 1 FIX-FIRST (fixed `af890b4`),
  round 2 FIX-FIRST, prose-only (fixed `01cf2ca`); bot rounds
  adjudicated with three accepted fixes (`b031706`) and evidence-backed
  declines; all threads replied and resolved.

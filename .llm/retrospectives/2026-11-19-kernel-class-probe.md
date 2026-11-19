# Retrospective: `2026-11-19 kernel-class probe`

## Work Under Review

- Scope: session 203's PR #409 — issue #408 (classify the kernel before
  trusting the group signal's `'empty'` verdict), nine commits across six
  pushed heads (initial probe; round-1 review fixes; causation via two
  members; pin-verification refusals; round-2 hardening; scripted test
  infrastructure), plus the issue work: #408 implemented, #249 addressed
  with a status comment, #387/#388/#389 drift streams verified, the
  CHANGELOG and PLAN decision lines updated.
- Trigger: large change; three bot review rounds (CodeRabbit round 1: 3
  findings, round 2: 8 findings; OpenAI: one finding on each of four
  heads) plus one fresh-context adversarial round; one self-caught
  design bug in the first test run.

## Findings

| # | Finding | Type | Evidence |
| --- | --- | --- | --- |
| 1 | A cache keyed on a domain value needs a distinct "unmeasured" sentinel: with `KERNEL_CLASS_UNKNOWN` as both the initial and the error state, the probe-once cache re-measured on every call. State the sentinel's semantics beside the cache declaration. | technique | first `KernelClassProbeTests` run failed `2 != 1` measurements; `_kernel_class = None` sentinel + comment in `owned_process.py` |
| 2 | Boolean liveness reads must classify every error direction explicitly: the first `_probe_member_alive` returned False for any `OSError`, so a failed read could fake a member death and cache a false `delivers` on a mid-band kernel. Catch the two termination exceptions (`ProcessLookupError`, `FileNotFoundError`) and let every other error propagate to `unknown`; the module's own doctrine ("a failed read is never evidence of a stop") applies to new code, not just reviewed code. | technique | CodeRabbit round 1, comment 4626418758; `_probe_member_alive` exception split + `test_the_observation_errors_never_fake_a_death` |
| 3 | When a measurement's causation can be attacked, prefer a structural control over documenting the race: one observed death cannot prove a group send caused it (an external kill in the observation window reads the same), and a documented residual drew a `major` on two later review rounds. Fork two members and require one send to stop both — two independent external kills in one window is the residue. | technique | OpenAI majors on `2bb404f`/`bf3a8a0`; `_PROBE_LEADER_CODE` two-fork shape; `test_the_probe_classifies_the_send_shapes` one-dead-member case |
| 4 | Cleanup after a kill must wait out kill delivery before verification sweeps (a mid-death member is otherwise named a survivor and downgrades the measured verdict), and a finalization loop must complete under interrupts: record the `BaseException`, close every pin, run the recycle-safe teardown, then re-raise so the cache stays unset. | technique | CodeRabbit round 1 comment 4626418781 and round 2 comment 4627162631; the `finally` finalization in `_measure_group_signal_kernel` |
| 5 | Fixture hermeticity is host-hermeticity: an unpatched `Path('/proc')` read inside a fixture with plausible fake pids reads the host's real processes (a busy container can own pid 4243 and flip a scripted shape), and real sleeps under shrunk deadlines let host pauses skip observation windows. Stub every identity read by default and drive timing through a scripted monotonic clock that advances only on sleeps. | technique | CodeRabbit round 2 comments 4627162662 and 4627162652; `_FakeProcPath` + `_ScriptedClock` in `test_owned_process.py` (probe tests now <0.1 s) |
| 6 | A module-level cache consulted by verdict paths makes tests order- and kernel-dependent: every mocked-send test must seed the classification explicitly, and the one real-kernel witness must reset it to unmeasured — otherwise a mid-band runner's cached `spares` flips a later mocked test and a mocked test poisons the witness. | technique | seeded `_kernel_class` in the three mocked-empty tests; cache reset in `test_pinned_group_signal_reaches_members_after_the_leader_is_reaped` |
| 7 | GitHub's `reviewDecision` stays `CHANGES_REQUESTED` through later `COMMENTED` reviews by the same bot; the terminal state for a fully addressed round is dismissing that review with the evidence-backed message (owner scope authorized), with each finding's fix reply and resolved thread as the record. | fact | dismissals of reviews 5972002794 and 5972980905; `reviewDecision` cleared to empty after each dismissal |
| 8 | An advisory bot-review run can complete green while posting the "Review incomplete" warning — the run on `895df13` covered no diff. Per #307 that is unavailable coverage on that exact head, recorded here and never claimed as a clean result; the review of record is the fresh-context adversarial round plus the complete feedback scan. | fact | run 44505026914 log ("Review incomplete… not a clean review"); this artifact and the session progress note |

## Actions Taken

| # | Action | Where it landed | Verified by |
| --- | --- | --- | --- |
| 1 | Kernel-class contract recorded: mid-band flag-4 kernels answer ESRCH beside live members; the probe classifies per process and fails `'empty'` verdicts closed; single-death causation needs two members | `../knowledge/transport-tooling.md` (this PR) | `make lint-llm` |
| 2 | Session findings and tallies recorded | `progress/session-203-kernel-class-probe.md` (machine-local) | n/a |

Routing: procedures → `.llm/skills/` (no new skill — the owned-process
docstrings carry the contracts); facts → `../knowledge/`; tooling gaps →
none this session.

## Prune Ledger

- Retired / merged / fixed at source: none — considered: transport-tooling
  already carries the #404/#405 pin facts; the probe entry extends that
  section instead of opening a second home.
- Verify-on-touch: the group-signal witnesses
  (`test_the_pinned_group_signal_reaches_a_same_group_descendant`,
  `test_pinned_group_signal_reaches_members_after_the_leader_is_reaped`)
  were re-run green on kernel 6.12.76 at every pushed head.

## Outcome

- State: `findings-acted`
- Follow-ups: #408 stays open for its remaining acceptance work (live
  mid-band-kernel classification evidence from a real runner is only
  available when a Gate runner of that class reports the
  `OWNED_PROCESS_GROUP_SIGNAL_FAILED` verdict); #249 stays open for the
  next actual install-hang failure's evidence; #276 unchanged (owner
  action required).

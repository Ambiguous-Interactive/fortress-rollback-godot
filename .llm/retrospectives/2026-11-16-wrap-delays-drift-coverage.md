# Retrospective: 2026-11-16 wrap-delays drift-coverage

## Work Under Review

- Scope: session PR #383 (branch `feat/wrap-flood-delay-profiles`, six
  commits): ring-wrap flood under per-peer construction delays (#34/#59) with
  the endpoint fix the combination exposed, `p2p_wrap_regenerate --only`
  repair, M1 pin-advancement drift flow (#51), #55 coverage verifier, plus
  two adversarial review fix rounds.
- Trigger: large change (>300 lines, >10 files), new capability (verifier,
  advancement flow), incident (real oracle differential failure; two
  self-inflicted suite failures from mid-run tree changes).
- Evidence base: shrinker report `.cache/results/session191-wrap-472/`
  (2063→4 operations, packet 5 ack_frame 2 vs 1); red runs quoted in
  `progress/session-191-wrap-delay-drift-coverage.md`; final receipts
  complete/passed on both pins at the final head; `make gate`,
  `make test-reference` 40/40, `make test-oracle` 18/18, `make lint-source`
  537 files / 0 violations.

## Findings

| # | Finding | Type | Evidence |
| --- | --- | --- | --- |
| 1 | The two-year-old squashed-PR hazard is real and reproducible: #382's merge lost a one-line hoist (`provenance_path` used before assignment at `p2p_wrap_regenerate.py:51`), and the session only found it because it needed `--only`. Squash merges silently drop working-tree state that was never committed. | fact | red run: exact `UnboundLocalError` quoted in the progress file; fix in commit 5dae309 |
| 2 | Mid-run tree changes break receipt/snapshot identity guards — again. Creating a file during `test_godot_runner` (source snapshot sees `git ls-files --others`) failed the suite twice; committing a test file mid-corpus would have failed the launchers' `require_unchanged('repository identity')`. Session 190 recorded the same class only in a gitignored progress file, so it recurred — the budget rule "same finding in 3 retros means fix the system" was one occurrence away. | rule | `scripts/native_source_snapshot.py:21-23` (`git ls-files --others`), `p2p_launch.py` `require_unchanged` tail; two failed `test-reference` runs |
| 3 | Mutant-checking by `git diff > patch; checkout; apply` is a footgun: the captured patch went stale twice (re-applied a mutant, then restored a committed pre-fix file), each caught only because a test or grep noticed. Direct edits plus a post-checkout `grep` of the exact changed lines never mislead. | technique | session log, restore sequences around the coverage/drift mutant checks |
| 4 | The pinned upstream refuses to stage input flights whose decode reference (`start_frame - 1`) the receiver never held; the port staged past it. The combination of two previously passing axes (construction delays × ring-wrap flood) was required to expose it — corpus growth finds real bugs, not just checkbox coverage. | fact | `protocol/mod.rs` `on_input` else branch; shrink to 4 ops; fix `input_endpoint.gd::_receive_frames` (commit d7ea2e1) |
| 5 | Evidence-capture runs at the "final head" must be the last thing a session does. Every late commit (retro, docs, CHANGELOG) invalidates receipts that bind commit + dirty state; planning the commit order before the long runs saves a full corpus re-run. | technique | this session's corpus ran three times; only the last run is citable evidence |

## Actions Taken

| # | Action | Where it landed | Verified by |
| --- | --- | --- | --- |
| 1 | Systematized finding 2+3: receipt/tree-identity guards documented with the never-touch-the-tree-during-a-run rule and the patch-staleness technique | `.llm/skills/testing/references/oracle-validation.md` (closing section) | `make lint-llm` |
| 2 | Decoder-reference contract documented next to the wire payload it governs | `docs/protocol.md` (Message payloads section) | PR review |
| 3 | Production fix + deterministic unit case (red at exactly three assertions pre-fix, both runner repeats) | `input_endpoint.gd`, `test_input_endpoint.gd::reference_skip` | minimized differential matches both pins |
| 4 | `--only` regeneration made to work and to admit genuinely new profiles; regression test drives the real loader | `p2p_wrap_regenerate.py`, `test_p2p.py` | red against `UnboundLocalError`; skip-rule mutant fails the loader probe |

## Prune Ledger

- Retired / merged / fixed at source: session-190's progress-file-only note on
  this failure class superseded by the durable reference entry (fix at
  source); no stale skill claims found (`grep -ri "mid-run\|require_unchanged" .llm/`).
- Verify-on-touch: `make lint-llm` re-run after the reference edit; the
  oracle-validation entry's commands (`require_unchanged`, snapshot guards)
  are the ones this session exercised.

## Outcome

Retro: findings-acted

# Retrospective: 2026-11-22 encoding contract and live donor retry

## Work Under Review

- Scope: the `.llm` encoding meta-lint and its self-tests; the
  `peer-drop-missing` live witness, its test transport, validator and limits;
  docs, PLAN and knowledge notes.
- Trigger: #438, the missing-final-LF gap from session 218; the #188 live
  missing-history slice.
- Evidence base: a minimal-root mutant probe, `make lint-llm`,
  `make test-llm`, `make lint-source`, `make gate`, the Python reference
  suites, and live Chromium/Firefox runs on both pins.

## Findings

| # | Finding | Type | Evidence |
| --- | --- | --- | --- |
| 1 | The encoding contract lived only in prose: `check_encoding` rejected BOM and CRLF but accepted a file without its final LF, so the retrospective that triggered #438 passed. A documented invariant is not a check until a mutant fails it. | design | pre-fix minimal-root probe returned no findings; `.llm/context.md` without its last LF (`PRE-FIX ACCEPTED MUTANT: True`) |
| 2 | The contract names every harness file, but the existing scope was markdown plus pointers and stubs. Code samples and the generated index were outside it. | bug | `.llm/code-samples/*.gd` was never read by `check_encoding`; the non-markdown self-test failed before `encoding_scope_files` |
| 3 | A page index is not a roster slot. The first live arm dropped history on page 1, but page 0 was the donor (`slot: 2`) and page 1 was the coordinator (`slot: 0`), so the drop never fired and the validator failed with both rows at `history_dropped: 0`. | bug | first live run: donor `slot: 2`, `history_dropped: 0`; validator `peer-drop live missing-history donor retry incomplete` |
| 4 | Arming both survivors is safe because only the selected donor publishes `BACKFILL`/`HISTORY` bytes. Binding the count to the row whose slot equals `history_donor` removes the page/slot assumption entirely. | design | four live cells: donor row `history_dropped: 1`, proposer row `history_installed: true` |
| 5 | A whole-carrier drop at the real send boundary proves a retry only if the packet is the donor's first history chunk and a later chunk-zero packet of the same operation is kept: the transfer cursor reaches the journal end, the retry window expires, and the donor resends from zero. A bare drop counter could be incremented without removing a packet, and a later duplicate drop would prove nothing. | review | adversarial round 1 finding 8 and OpenAI inline on `webrtc_setup.gd:265`; `arm_history_drop` records chunk 0, its operation and count, and `_history_resends` counts only kept chunk-zero packets of the same operation; the validator requires all of them |
| 6 | The pre-fix validator accepted every new donor-retry mutation, including a fabricated count and a missing field. The mutation table must run against the old module to prove each new requirement binds. | review | the original validator accepted `5/5`; the first-strengthened version accepted `7/22`; the final validator rejects all twenty-two with `peer-drop live missing-history donor retry incomplete` |
| 7 | The coordinated-drop PLAN row is a remaining-outcome map, not a status log. Adding `donor-retry fence witnessed` duplicated the live status that `docs/peer-lifecycle.md` already owns, so the row keeps only the remaining pinned comparison and schedules. | review | CodeRabbit inline on `PLAN.md:94`; the row was reverted while the lifecycle doc keeps the witness status |
| 8 | A non-UTF-8 harness file crashed `check_pointers`, `check_context` or `check_links` before the encoding finding could print. The content checks must read through a helper that yields no text on a decode failure, leaving the named encoding error authoritative. | review | adversarial round 1 finding 1; invalid UTF-8 in `.llm/context.md` now reports `not valid UTF-8` instead of a traceback |
| 9 | The walk included editor artifacts and missed `PLAN.md`/`GOAL.md`. A text-suffix allowlist keeps `.DS_Store` and `notes.md.bak` out, while the two root contracts join the scope; the `__pycache__` filter now inspects the path below `.llm` rather than every ancestor. | review | adversarial round 1 findings 2, 4 and 5; new self-tests cover artifacts, both root files and a checkout below a `__pycache__` directory |

Advisory, not fixed: a symlinked directory under `.llm` is not traversed, and
a NUL byte is valid UTF-8 so it is not rejected. Neither shape exists in the
harness and neither is part of the documented contract; a symlink or NUL policy
would be a new boundary, not a defect in this change. The live history filter
has no separate native unit seam because `webrtc_setup.gd` preloads the
export-only `res://webrtc_game.gd`; the merge-queue Reference Baseline runs the
real label, so a copy of the filter in a unit test would not test production.
The donor counters are self-reported by the page; the live code removes the
packet and the merge-queue run qualifies the honest path, but a hostile page
could fabricate the counts. An independent transport capture would be a new
witness, not a correction to this one.

## Actions Taken

| # | Action | Where it landed | Verified by |
| --- | --- | --- | --- |
| 1 | Reject a missing or doubled final LF and name the file. | `scripts/llm/lint_llm_instructions.py` | direct mutant run exits 1 with the path |
| 2 | Cover every text harness file under `.llm/`, plus `PLAN.md`, `GOAL.md`, pointers and stubs, while skipping editor artifacts and `__pycache__`. | `scripts/llm/llm_paths.py` `encoding_scope_files` | 20 meta-lint tests; `make lint-llm` |
| 3 | Add missing-LF, double-LF, BOM, CRLF, invalid UTF-8 (context, pointer, skill), artifact, root-contract, extra-text-suffix and code-sample self-tests. | `scripts/tests/test_llm_instructions_lint.py` | 20 tests pass; pre-fix run had 3 failures |
| 4 | Withhold the donor's first retained-history chunk on its real link. | `scripts/reference/browser/webrtc_setup.gd`, `webrtc_drop.gd` | live Chromium/Firefox on 4.3 and 4.7.2 |
| 5 | Require the drop count, chunk zero, its operation/count and a later chunk-zero resend beside the installed interval. | `scripts/reference/browser/webrtc_drop.py`, `test_webrtc_drop.py` | 22/22 mutations rejected; 40 reference tests pass |
| 6 | State the donor-driven resend in the probe limits, lifecycle docs and knowledge; keep PLAN status-free. | `signalfish_webrtc_probe.py`, `docs/peer-lifecycle.md`, `.llm/knowledge/` | `make lint-llm`, `make lint-source` |
| 7 | Read content checks through a decode-safe helper so an invalid UTF-8 file names itself instead of crashing. | `scripts/llm/lint_llm_instructions.py` | invalid-UTF-8 self-test; direct run names the file |
| 8 | Make `validate_skill_dir` return a named error for invalid UTF-8, so the index and stub generators do not crash before the meta-lint. | `scripts/llm/llm_frontmatter.py` | invalid `SKILL.md`: index and stubs exit 1 with `zz-bad: SKILL.md is not valid UTF-8` |

## Prune Ledger

- Retired: the claim that `peer-drop-missing` only proves a first-send
  transfer. The docs now state the chunk retry.
- Verify-on-touch: `make test-llm`, `make lint-llm`, `make lint-source`, the
  Python reference suites, and the live `peer-drop-missing` label on both pins
  and both browsers.
- No new abstraction: `encoding_scope_files` reuses the size-scope helper, and
  the live arm shares `DropDirect`'s existing packet scan.

## Outcome

- State: `findings-acted`
- Follow-ups: #188 keeps the pinned-source comparison and the remaining live
  cases; #166 keeps complete pinned barrier parity.

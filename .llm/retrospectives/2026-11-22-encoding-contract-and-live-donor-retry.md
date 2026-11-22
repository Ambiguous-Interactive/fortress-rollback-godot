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
| 5 | A whole-carrier drop at the real send boundary proves a retry only if the packet is the donor's first history chunk: the transfer cursor reaches the journal end, the retry window expires, and the donor resends from zero. A drop counted after installation would prove nothing. | design | `arm_history_drop` decrements on the first outgoing `BACKFILL`/`HISTORY` packet; the recipient row shows `history_installed: true` only with the donor count at 1 |
| 6 | The pre-fix validator accepted every new donor-retry mutation, including a fabricated count and a missing field. The mutation table must run against the old module to prove the new requirement binds. | review | `PRE-FIX validator accepted 5/5`; post-fix rejects all five with `peer-drop live missing-history donor retry incomplete` |
| 7 | The coordinated-drop PLAN row is a remaining-outcome map, not a status log. Adding `donor-retry fence witnessed` duplicated the live status that `docs/peer-lifecycle.md` already owns, so the row keeps only the remaining pinned comparison and schedules. | review | CodeRabbit inline on `PLAN.md:94`; the row was reverted while the lifecycle doc keeps the witness status |

## Actions Taken

| # | Action | Where it landed | Verified by |
| --- | --- | --- | --- |
| 1 | Reject a missing or doubled final LF and name the file. | `scripts/llm/lint_llm_instructions.py` | direct mutant run exits 1 with the path |
| 2 | Cover every file under `.llm/` plus pointers and stubs. | `scripts/llm/llm_paths.py` `encoding_scope_files` | code-sample self-test; `make lint-llm` |
| 3 | Add missing-LF, double-LF and code-sample self-tests. | `scripts/tests/test_llm_instructions_lint.py` | 14 tests pass; pre-fix run had 3 failures |
| 4 | Withhold the donor's first retained-history chunk on the real link. | `scripts/reference/browser/webrtc_setup.gd`, `webrtc_drop.gd` | live Chromium/Firefox on 4.3 and 4.7.2 |
| 5 | Require the donor drop count beside the installed interval. | `scripts/reference/browser/webrtc_drop.py`, `test_webrtc_drop.py` | 5/5 mutations rejected; 40 reference tests pass |
| 6 | State the retry in the probe limits, lifecycle docs and knowledge; keep PLAN status-free. | `signalfish_webrtc_probe.py`, `docs/peer-lifecycle.md`, `.llm/knowledge/` | `make lint-llm`, `make lint-source` |

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

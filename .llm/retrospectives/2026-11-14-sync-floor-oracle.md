# Retrospective: 2026-11-14 session-engine global-floor oracle

## Work Under Review

- Scope: PR #358 (squash `604b454`) — new `sync_floor` oracle: launcher,
  contract, corpus, Rust SyncLayer harness with isolated-copy access-only
  hooks, Godot trace script, unit tests, CI wiring, docs, changelog. Eleven
  files, ~800 changed lines across seven commits (two feature, five
  review-fix).
- Trigger: large change + new capability (new differential subsystem).
- Evidence base: both engine pins green twice locally; PR CI 55 checks pass;
  merge-triggered main Reference Baseline 53 jobs green; two adversarial
  rounds (2 + 6 findings, all fixed); CodeRabbit four inline findings fixed
  and resolved; `make lint-source` 0 violations; oracle unit suites 17 files
  green.

## Findings

| # | Finding | Type | Evidence |
| --- | --- | --- | --- |
| 1 | Read the pinned source exhaustively before writing: the harness fidelity claims (facade advance order, receipt-minimum, completion trim) survived two adversarial rounds without a parity finding. The three real divergences the differential caught were semantic discoveries the codebase did not document: the receipt minimum includes unserved slots at -1, the Session trims queues at batch completion while the facade discards pre-advance at confirmed-1, and the facade writes two identical frame-0 saves. | technique | `.cache/reference/results/sync-floor/` divergence runs during development; `sync_floor.rs` advance_cycle comments |
| 2 | GDScript literals above i64 max corrupt the whole script's constant pool; the visible failure pointed at unrelated logic. 64-bit hashing needs computed constants, documented wrap, and 32-bit-half formatting. | fact | `.llm/knowledge/gdscript-runtime.md` row added; wrap probe output `hex=af63bc4c8601b62c` equals Python's unsigned result |
| 3 | `JSON.parse` floats plus silent `int()` truncation defeat float-mutant artifact controls; whole-number guards must precede comparisons. | fact | `.llm/knowledge/gdscript-runtime.md` row added; float-mutant control exit codes 0 → 2 |
| 4 | Two review rounds converged on the same theme: anything the contract does not derive from the schedule is only cross-engine-checked, so identical-wrong values pass. Each round added derivations (receipt identity, statuses, delay fields, floor-row bytes, range ends) and each derivation matched the real traces on first run. | rule candidate | `scripts/oracle/sync_floor_contract.py` validate_record; round-two review probes |
| 5 | The one failed CI job of the session (`Reference negative controls`, `test_browser_cleanup.py` TimeoutExpired at a 10-second Node bound) was unrelated to the diff and passed on re-run — a hosted-runner scheduling flake in an untouched suite. | none | `gh run 43526628906` failed job log; re-run green |

## Actions Taken

| # | Action | Where it landed | Verified by |
| --- | --- | --- | --- |
| 1 | Two GDScript runtime facts recorded with wrap-probe and control evidence | `.llm/knowledge/gdscript-runtime.md` | `make lint-llm` OK |
| 2 | Findings 4's derivation principle stays in the oracle's own unit tests and controls (committed), not a new skill — the existing oracle family already encodes the pattern | `scripts/oracle/test_sync_floor.py` | mutation tests green |
| 3 | No stale claims retired: grep of `.llm/` found no conflicting floor/oracle guidance; `gdscript-style` already covers typing conventions touched here | — | `grep -ri floor .llm/skills` clean |

Routing check: no new skill (no reusable procedure beyond what the oracle
family already documents); facts went to the lowest level (knowledge).
`make llm-index && make lint-llm && make test-llm` green.

## Outcome

Retro: findings-acted

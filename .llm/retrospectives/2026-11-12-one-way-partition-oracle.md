# Retrospective: `2026-11-12 one-way-partition-oracle`

## Work Under Review

- Scope: `partition_one_way` lifecycle case added to the P2P differential
  oracle (2 corpus files, 1 doc, PLAN/CHANGELOG notes; +51/-3 lines, PR #355).
- Trigger: external knowledge (upstream #386/#387 triage and pinned-source
  trace archaeology) plus new-capable observation coverage in an existing gate.
- Evidence base: scoped `p2p_launch.py --case partition_one_way` receipts on
  Godot 4.3 and 4.7.2 (twice, fresh processes), all 10 lifecycle mutation
  controls failing at declared diagnostics, `make test-oracle` 16/16,
  `make lint-source` 505 files clean.

## Findings

| # | Finding | Type | Evidence (file:line / command / measurement) |
| --- | --- | --- | --- |
| 1 | The first documentation draft asserted a wrong causal mechanism ("an interrupted endpoint stops sending gameplay traffic"); the trace proved peer 1 kept sending inputs after its interruption, and the fed peer's interrupt actually came from the schedule's own final one-second clock jump. Causal prose written before reading the emitted trace is a recurring hazard in oracle work. | rule (existing, re-applied) | `progress/session-175-one-way-partition.md`; trace packets 20–30 in `.cache/session175/partition-source.json`; corrected paragraph in `docs/oracle-p2p.md` |
| 2 | Existing corpus builders already encode schedule assertions inside `build()` (early-exit and terminal-shape guards), so the new case needed no comparator changes at all — the "no new projection logic" outcome was achieved by reusing that pattern. | fact (reinforce) | `scripts/oracle/p2p_lifecycle_corpus.py` (`partition_one_way` branch); `scripts/oracle/p2p_lifecycle.py` `terminal_projection` unchanged |

## Actions Taken

| # | Action | Where it landed | Verified by |
| --- | --- | --- | --- |
| 1 | Rewrote the doc paragraph from the actual trace before push; no new store entry because docs/verification-policy already owns the evidence-first rule. | `docs/oracle-p2p.md` | trace re-read; `make lint-source` |
| 2 | No skill/knowledge write: the general rule ("verify causal claims against emitted evidence") is already owned by `docs/verification-policy.md` and the oracle guide's existing receipt discipline; adding a second home would shadow it. | none (documented decision) | `grep -ri "evidence-first" .llm docs` review |

## Prune Ledger

- Retire: nothing (no store entry was invalidated).
- Merge: none needed; #2 reinforces an existing pattern, not a duplicate entry.
- Verify on touch: the scoped launcher command still passes post-reflow of the
  corpus name tuple (receipt `.cache/session175/p2p-oracle-final`).

## Outcome

Retro: findings-acted

# Retrospective: `2026-11-16 wrap flood at the default ring — counts three through eight`

## Work Under Review

- Scope: issue #379's option 1 in one session PR — extend the ring-wrap
  flood corpus to the production default 128-row ring at counts three
  through eight (the issue's five-through-eight acceptance plus the
  three-peer gap CodeRabbit caught), raise the scenario-operation bound
  deliberately from 10000 to 20000 in all three validators with hostile
  tests pinning the boundary, follow the raw-trace stdin guard to 32 MB,
  and reserve 45-minute headroom for the oracles wave. PR #380. Session
  log: `progress/session-189-wrap-flood-default-capacity.md`.
- Trigger: session goal (address open issues by gameplay impact; one PR;
  under two hours).
- Evidence base: measured extrapolation before any bound change
  (4564-op run in 1.35 s, ~1.4 KB raw per op, 98 s five-peer build),
  per-case differential receipts on both pinned engines (twice per side,
  raw compression validation, seven controls per case), 236+ tooling
  tests, the whole unit inventory, Gate + Devcontainer Verify + the
  queue's grouped qualification.

## Findings

| # | Finding | Type | Evidence |
| --- | --- | --- | --- |
| 1 | Committing while evidence runs execute invalidates them: the launchers pin `git_identity()` at start and re-verify at end, so a mid-run commit fails every in-flight case at "evidence identity changed: repository identity" and costs a full re-run of ~14 minutes per engine. | process (self-inflicted, cost one round) | first wrap verification round discarded; re-run clean against `fc05637` |
| 2 | Coverage prose drifts from the corpus it describes: "every count two through eight" shipped while `PROFILES` had no three-peer case. The fresh-context bot reviewer caught it; the author's own reading did not. | defect (caught by review) | CodeRabbit inline finding at `docs/oracle-p2p.md:359`; fixed by adding `mesh_3_wrap_flood`, not by weakening prose |
| 3 | Measured extrapolation chose the bounds correctly the first time: the ~1.4 KB/op and ~3400 ops/s measurements predicted the 24 MB compact trace and ~12 minutes of builder cost; no bound needed a second adjustment after the eight-peer case ran (16,324 operations, compact trace ~23 MB against the 32 MB guard). | fact (method worked) | receipt sizes vs guards, session log table |
| 4 | The flaky `test_owned_process` failure under parallel load reproduces only in full-suite runs and passes standalone and on re-run; it is unrelated to oracle changes and remains a known timing-sensitive suite. | fact (pre-existing flake) | first `make test-reference` run failed one file; full re-run passed 38/38 |
| 5 | A parent issue (#379) can name an option ("raise the bound with its hostile unit tests") whose test coverage does not yet exist: the 10000 bound had no pinning test on either side, so "update its unit tests deliberately" meant writing both pins, not editing them. | fact (issue wording) | new `hostile_operation_counts_fail_before_execution` and `test_operation_inventory_bound` |

## Actions Taken

| # | Action | Where it landed | Verified by |
| --- | --- | --- | --- |
| 1 | Session log records the invalid round and the re-run's commit, so the evidence trail names its own identities. | `progress/session-189-...md` | receipts' commit field |
| 2 | Corpus and prose reconciled by completing the corpus (count three) instead of hedging the claim. | `p2p_wrap.py`, `docs/oracle-p2p.md`, `CHANGELOG.md` | mesh_3 receipts on both pins; seven controls |
| 3 | (this file) The commit-before-evidence-run ordering is recorded so the next session does not rediscover it. | `.llm/retrospectives/2026-11-16-wrap-flood-default-ring.md` | — |

## Nothing Pruned

No prior guidance became stale. The testing skill's deterministic-runner
rules, the harness file caps and the ship-session flow ran unchanged; the
feedback scan, reply-and-fix disposition and queue flow matched the #307
policy as written.

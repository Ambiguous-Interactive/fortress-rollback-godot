# Retrospective: 2026-10-10 rollback core

## Work under review

New shared session engine, tagged snapshot history, queue floor reclamation,
thin game driver and actual production-session oracle execution.
Trigger: new subsystem, state/ownership changes and adversarial corrections.
Evidence: session log, engine receipts, scoped/full review probes and source diff.

## Findings

| Finding | Evidence | Action |
| --- | --- | --- |
| Actual request execution establishes a stronger boundary than replaying Rust decisions | 21 cases / 2352 requests per repeated engine run in `scripts/oracle/launch.py` | Updated oracle/session docs and retired stale implementation claims |
| Godot versions differ when stringifying parsed integral floats | Current-engine strict schema rejected 1.0; explicit numeric reconstruction passed both engines | Added testing-skill procedure; retained strict Python schemas |
| Callback lifetime can survive batch termination | Full adversarial callback terminated and reconfigured before returning, leaving game/session frames different | Add independent callback guard and regression; record owning rollback invariant |
| Raw queue startup padding cannot confirm unreceived remote history | First remote frame 3 produced fabricated confirmed frames 0–2 | Enforce sequential remote receipt at session boundary |
| Read views must not expose construction mutators | FrameInputs.append changed roster size and allocated after expiry | Populate internally; expose checked reads only |
| Error projection must parse the pinned structured category | Substring matching accepted an arbitrary error containing MissingLocalInput | Anchor the exact Debug diagnostic shapes; keep malformed variants as negative controls |
| Concurrent reference launchers share destructive extraction | Two launches raced fetch.py extraction; FileNotFoundError before game execution | Run source/bootstrap-dependent oracle launchers sequentially |

| GitHub capability gaps require authenticated fallback and a complete credential check | User required MCP first and authenticated gh; checking only environment and gh config missed a usable configured Git credential helper and caused an unnecessary wait | Added canonical routing skill, noninteractive helper lookup and endpoint validation; linked applicable guidance and removed the REST fallback rule |

## Routing and prune ledger

The authenticated CLI replacement has a real-tool positive control alongside
mocked malformed responses. `gh api --verbose` changes the normal output writers;
private child-process `GH_DEBUG=api` preserves `--include` headers and JSON.
The helper rejects redirected evidence and redacts configured credentials.
This operational detail remains with the tested helper rather than a second skill.

Updated existing testing/rollback skills instead of adding overlapping stores.
Added one GitHub operations skill to own tool routing and credential handling;
existing delivery/review/copy guidance links it rather than duplicating its rules.
Canonical context, README, PLAN and oracle docs no longer say the local session
engine is absent. P2P/browser limitations remain explicit and verified separately.
No release coverage status or applicability ledger flag was promoted.

Re-ran `make llm-index`, `make lint-llm`, `make test-llm`, source-width lint and
minimum/current runtime checks against the replacement guidance.

## Outcome

State: `findings-acted`.
Follow-ups remain in #59/#61 and the existing C3/C4/C5/A1 task issues; session
parity here is scoped to local sync-test, not protocol or release completeness.

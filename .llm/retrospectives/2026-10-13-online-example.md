# Retrospective: 2026-10-13 online example

## Work under review

- Scope: optional SDK lobby, playable online scene, bounded transport caller,
  deterministic cases and an actual exported-browser witness under #81/#41.
- Trigger: new user-facing capability, SDK integration and review corrections.
- Evidence: six focused cases on both pins, full native unit target,
  actual release exports and independent adversarial review.

## Findings

| Finding | Type | Evidence |
| --- | --- | --- |
| Optional resources must survive release-export remapping. | Fact | `examples/online/lobby.gd:40` uses `ResourceLoader.exists`; actual SDK loading succeeds in exported gameplay. |
| Teardown can reset observer display defaults without resetting real simulation history. | Technique | Fresh review identifies the zero-frame witness; `online_bridge.gd:62` now reads actual peer status after detach. The verifier rejects synthetic zero, lost frontier and post-failure advancement. |
| Handshake timeout reports an event while synchronization continues. The example must choose its own terminal policy. | Existing contract | `docs/handshake.md:77`; `test_online_example.gd` exercises exactly 30 seconds and the first microsecond afterward. |
| Concurrent source edits invalidate browser receipts even when gameplay passes. | Existing technique | The exploratory run refuses publication after its input inventory changes; final runs use frozen sources and isolated stages. |

## Actions taken

| Action | Canonical home | Verification |
| --- | --- | --- |
| Record optional runtime resource lookup. | `../knowledge/transport-tooling.md` | Real release exports and SDK-absent native scene loading. |
| Replace narrow terminal-mutant wording with authoritative frontier checks. | `../skills/testing/SKILL.md` | Four verifier controls and real one-sided leave followed by fresh-room play. |
| Keep diagnostic timeout semantics in their existing source. | `../../docs/handshake.md` | Exact-boundary deterministic case; no duplicate knowledge entry. |

## Prune ledger

- Fixed at source: terminal-freeze guidance now covers observer resets as well
  as mutations. Existing secure-context WSS guidance is reused in the guide.
- Considered retirement/merging: no stored fact became obsolete; no new skill
  or duplicate timeout entry is added.
- Generated source metadata is removed only when newly paired with existing
  tracked inputs. Final browser evidence is rerun after cleanup.

## Outcome

- State: `findings-acted`.
- Follow-ups: #38/#75 retain advanced recovery, #39 retains the browser release
  matrix, and #41 retains broader examples/migration acceptance.

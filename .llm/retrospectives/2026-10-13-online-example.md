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
| Independent peer startup exposes traffic that a global witness barrier hides. | Technique | Hosted 4.7.2 stops at frame zero; `test_online_startup.gd` reproduces final-reply reordering on direct/relay and verifies original bytes after changed keys. |
| Render-time observation cannot rely on a short-lived rollback snapshot ring. | Technique | Hosted 4.3 keeps only 83/47/36/64 prefixes. The actual 100-step Session regression returns 8 before repair and 99 afterward. |
| A version-labelled prerelease URL can overwrite and delete its reviewed bytes. | Fact | Fresh TLC hash differs; upstream master workflow deletes old jar assets and moves the tag. The exact reviewed fixture retains the existing formal controls. |

A final runner-control incident is reduced to two unused suites. Loading the
optional connection factory only during SDK-backed setup repairs its script
resource leak. Both pins pass all six fail-closed runner controls; both actual
release exports retain successful gameplay and corruption rejection. This
remains a scoped implementation finding, not a new general engine rule.

Hosted full-suite watchdogs also require measured workload evidence. A cache-only
per-case trace completes every case; new cases add six seconds locally. The
full-suite budget becomes 180 seconds while completeness, repeat equality,
engine-error rejection and every assertion remain unchanged. No benchmark
claim follows from worker wall time. The unchanged both-pin ownership gate
moves to one parallel job, retiring duplicate invocation from each engine job.

## Actions taken

| Action | Canonical home | Verification |
| --- | --- | --- |
| Record optional runtime resource lookup. | `../knowledge/transport-tooling.md` | Real release exports and SDK-absent native scene loading. |
| Replace narrow terminal-mutant wording with authoritative frontier checks. | `../skills/testing/SKILL.md` | Four verifier controls and real one-sided leave followed by fresh-room play. |
| Keep diagnostic timeout semantics in their existing source. | `../../docs/handshake.md` | Exact-boundary deterministic case; no duplicate knowledge entry. |
| Record independent startup validation and inert discard. | `../skills/networking-transport/SKILL.md` | Direct/relay final-reply reordering, hostile packets and exact original recovery on both pins. |
| Preserve the reviewed TLC fixture and content identity. | `../../scripts/oracle/tools/README.md`, `../knowledge/transport-tooling.md` | Artifact/cache controls and the full 26-scenario handshake/formal gate. |

## Prune ledger

- Fixed at source: terminal-freeze guidance now covers observer resets as well
  as mutations. Existing secure-context WSS guidance is reused in the guide.
- Considered retirement/merging: no stored fact became obsolete; no new skill
  or duplicate timeout entry is added.
- Generated source metadata is removed only when newly paired with existing
  tracked inputs. Final browser evidence is rerun after cleanup.
- Removed the peer example's early-packet workaround; the protocol boundary
  now owns validation for every adapter. Retired dependence on a mutable TLC
  URL without changing reviewed checker semantics.

## Outcome

- State: `findings-acted`.
- Follow-ups: #38/#75 retain advanced recovery, #39 retains the browser release
  matrix, and #41 retains broader examples/migration acceptance.

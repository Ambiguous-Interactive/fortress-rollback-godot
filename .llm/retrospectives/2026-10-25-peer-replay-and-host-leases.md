# Retrospective: peer replay capture and shared host leases

## Work under review

- Scope: public peer final-state capture, online Finish replay, and cross-checkout host capacity.
- Trigger: new client capability and reproduced infrastructure defects.
- Evidence: encoded-peer last-input divergence, independent downloaded-byte checks,
  real two-root contenders, and fresh adversarial reviews.

## Findings

| Finding | Evidence | Action |
| --- | --- | --- |
| A checkout-local lock cannot coordinate a machine-wide resource. | The two-root control in `scripts/tests/test_host_capacity_roots.py` excluded root A but admitted root B before repair. | Use one host-account lock and test actual acquisition from independent roots. |
| Shared lock files need stable inodes and protected directories. | The first adversarial review reproduced replacement under a writable pre-existing directory; cleanup controls exercise a live owner. | Validate opened directory ownership/mode; preserve the inode through idle cleanup too. |
| An exit timeout does not bound a readiness read. | New silent and partial-line subprocess controls exercise the startup watchdog. | Bound readiness with selectors and reap stalled children. |
| A wrapper's notification can clear another facade's guard. | `test_peer_replay_capture.gd` reproduced `[BUSY, READY]` inside a second driver's notification; the repaired result is `[BUSY, BUSY]`. | Apply shared mutation preflight before peer capture and notification. |

## Curation and verification

Updated the existing [infrastructure evidence](../skills/testing/references/infrastructure.md)
with cross-root acquisition, stable-inode cleanup, directory validation and startup watchdog rules.
The [rollback skill](../skills/rollback-fundamentals/SKILL.md) already requires shared notification
guards; its existing rule remains authoritative without a duplicate.

The host, root and prune controls pass 49 tests. Both engine pins pass the four new
peer capture cases and five online diagnostics cases twice. The independent online
checker passes 31 controls. Full runtime, browser and delivery receipts remain in
the machine-local session log and the linked issues.

Prune ledger: replaced the stale terminal-replay planning statement and the checkout-local
lock description at their sources. No other knowledge entry was superseded.
Harness regeneration, integrity checks and self-tests verify the guidance update.

## Outcome

State: `findings-acted`.
Remaining broader replay, spectator-network and release gates stay in their existing issues.

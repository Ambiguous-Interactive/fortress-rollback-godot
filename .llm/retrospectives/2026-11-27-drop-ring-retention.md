# Retrospective — 2026-11-27 drop ring retention

## Findings and actions

The asymmetric retention case used the shared test builder's 128-row queue.
Its donor reached target frame 22, so that case could pass without reusing a
physical slot. The separate journal test forced reuse in a local-only session.

The asymmetric case now runs at the 18-row mesh minimum with prediction
window eight and zero input delay. Frame 22 overwrites frame 4's slot, and
the original target row at frame 8 remains available for the live recipient.
The shorter control uses the same capacity and keeps frame 4. Both cases
certify the raised cut and compare the continued canonical game history.

A controlled run that omitted the target receipt fold on the donor raised
its reclamation floor from 7 to 14. Its first missing original row was no
longer readable for recovery, both survivors refused the cut, and the
focused runner exited 1. The physical wrap check and the protected logical
retention check observe distinct events.

## Outcome

State is `findings-acted`. The [oracle evidence guidance](../skills/testing/references/oracle-validation.md)
now requires both observations. The [lifecycle contract](../../docs/peer-lifecycle.md#unequal-confirmation-frontiers)
explains which receipt and membership conditions protect the row. This
replaces the earlier open-ended physical eviction claim for the scoped live
mesh. The [pinned-source comparison](../../docs/oracle-p2p.md) keeps the
remaining terminal and membership cases under #188 and #48.

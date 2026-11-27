# Retrospective — 2026-11-27 Fortress v6 advance

## Work under review

Move the differential baseline and optional native package source to the
archive reviewed in [#546](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/546).
The operator and Gate independently verify the reviewed archive decisions.
The inventory records lexical discovery and preserves scoped historical audits.

## Findings and actions

| Finding | Evidence and action |
| --- | --- |
| The previous lexical inventory does not follow a pin update. | `inventory.py` reported source drift against the verified v6 tree. Regenerating it found 741 files and 383 source families. All six prior scoped notes remain pending, with their historical evidence. Four removed identities contained only generated pending entries. |
| The archive filename used by the active cache is not a source identity. | Offline fetch returned a digest mismatch at `downloads/fortress.tar.gz`. Both exact archive digests were verified and preserved by revision before installing the new active cache entry. |
| A full path rationale does not fit on one JSON source line. | `make lint-source` returned 320 violations for inline evidence. The operator now reads evidence references with short paths, anchors, and paragraph hashes. The companion review preserves the complete rationale without a linter exemption. |
| Formal and runtime receipts can accidentally mix tool, binary and manifest snapshots. | The reviewed manifest bytes now select both TLC and the source archive. Each Rust spectator result reports the compiled source revision, and the receipt requires the selected identity in every workload. |
| Higher-level locks do not protect receipt writes triggered by invalid arguments. | The engine launcher suite holds the formal output claim while launching competing commands. A normal execution and an argument error both leave the owner's receipt intact. Concurrent TLC seeding keeps the first installed artifact and verifies its digest. |
| A wire upgrade can preserve a scoped Godot policy difference. | The archive review records the v6 witnessless timeout refusal and the existing Godot last-survivor freeze. Tests exercise preserved canonical history. [#48](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/48) owns partition-policy alignment. |

## Evidence

- The partial operator run previously exited 1 and named all 64 unresolved
  paths without changing the copied pin. The complete run reported
  `advancement recorded: 320 review decision(s)`. [Archive review](../../docs/reference/pin-reviews/fortress-25e8020d1a5fd40c4f16b37f97b5ec5329a8566d.json)
- The exact v6 reference run passed 123 queue, eight sync-test, three network,
  one repeated-trace and one seeded-state-divergence test twice. Source,
  feature and output identities stay in the result.
- Both built packages and the source-paired oracles use the same reviewed
  archive digest. The separate experiment covered 12 platform and editor cells.
  [Native qualification](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/actions/runs/46072793492)

## Prune ledger

Updated the obsolete current-inventory count and revision in
[INVENTORY.md](../../docs/reference/INVENTORY.md). The original
[baseline receipts](../../docs/reference/baseline.md) remain historical
records, along with archived v2 replay and profile expectations.

## Outcome

- State is `findings-acted`.
- [#53](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/53)
  retains continuing release evidence and remaining milestone work.

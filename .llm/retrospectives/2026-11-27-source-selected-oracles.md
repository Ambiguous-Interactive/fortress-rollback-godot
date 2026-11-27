# Retrospective — 2026-11-27 source-selected oracles

## Work under review

Requalified the archive selection path for the Fortress v6 upgrade in #546.
The reviewed pin remains version 2. The same launchers can now read either
registered pin, compile the selected tree, and validate the resulting profile.

## Findings

| Finding | Evidence |
| --- | --- |
| Updating the pin separately from a Cargo dependency can mislabel results or fail inside a launcher. | The initial v6 rehearsal hit wire-version checks, stale replay revision checks, and queue and floor dependency anchors. The manifest-only rehearsal exercised the staged Cargo build path. |
| Receipt absence and pending repair require different controls. | The pressure schedule retained confirmed row 256 before its final service. The asymmetric schedule actually withheld delivery and exported the confirmed 256 and 255 row prefixes. |
| Native JSON decoding can discard conflicting duplicate keys before a type check. | The Rust P2P decoder now rejects a duplicate source revision or wire byte even when its last value matches. |
| A staged Cargo build must own the whole adapter directory. | A leftover `build.rs` would otherwise enter the cached floor adapter inventory and execute. The floor launcher now compares the expected adapter tree before building. |

## Actions taken

- Linked source decisions to the [archive review contract](../../docs/reference/README.md#observation-and-advancement).
- Captured the transport and build invariants in [transport tooling](../knowledge/transport-tooling.md) and [harness tooling](../knowledge/harness-tooling.md).
- Recorded legacy replay checksum behavior under its archived revision. The live candidate uses recovery-only final recording and compares the final canonical rows.

## Prune ledger

The historical v2 schedules, trace comparisons, and checksums retain their
original meaning. Rebuilding schedule hints changed their generator inventory
and preserved all 67 recipes.

## Outcome

- State: `findings-acted`
- Follow-up: finish the path-by-path archive review and native package qualification for [#53](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/53).

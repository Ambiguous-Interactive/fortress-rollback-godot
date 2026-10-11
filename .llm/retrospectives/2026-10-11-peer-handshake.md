# Retrospective: 2026-10-11 peer handshake

## Work under review

New bounded byte handshake endpoint, source differential and scoped formal
refinement, with native/Web and addon-only integration. Trigger: new subsystem
and review repairs. Evidence: [session log](../../progress/session-009-peer-handshake.md),
actual upstream source observations and independent fresh adversarial probes.

## Findings

| Finding | Type | Evidence |
| --- | --- | --- |
| A valid remote configuration difference belongs to agreement policy, not a corrupt-byte verdict. | Technique | Base codec rejects independent version/features and geometry goldens; repaired endpoint emits field-specific mismatch events. |
| Every queued control message can affect retry timing. | Technique | Pinned queue_message updates send time; request at 190 us incorrectly retried at 201 us before repair and waits through 390 us afterward. |
| Bounds must precede collection traversal, and accepted minima must permit progress. | Technique | Oversized-roster regression counts 100004 versus zero checks; accepted one-slot trace queue could not begin before the option repair. |
| Strict validation must precede normalization and selective projection. | Technique | False nullable upstream fields and an inserted midhistory activation survived comparison before review repair. |
| Formal action matching can omit an observed initial state. | Technique | Changed running/zero-roundtrip begin snapshot still passed TLC before the projector checked Init. |
| Extend the existing native/Web gate with canonical ordering. | Technique | Twenty-six-case matrices retain the exact alias control; initial native/Web divergence was solely suite order. |

## Actions taken

| Action | Canonical home | Verification |
| --- | --- | --- |
| Keep remote semantic/configuration fields parseable within absolute bounds. | [networking transport](../skills/networking-transport/SKILL.md), protocol guide | Independent byte goldens and endpoint mismatches on both pins |
| Audit queue timer effects and enforce cardinality before allocation. | Networking transport skill and endpoint | Timer boundaries, counted-work regression and maximum-roundtrip completion |
| Validate nullable fields and setup inventories before normalization. | [testing](../skills/testing/SKILL.md), oracle schema | Strict raw controls and complete transition comparison |
| Link initial and supported intermediate observations to the model. | Testing skill and formal projector | Real TLC positive consumption and intended-step negative controls |

## Prune ledger

Updated the existing networking/testing homes after searching `.llm/` for
overlap. No new skill or duplicated knowledge entry was created. The prior
strict-integer rule remains valid; nullable normalization and activation
inventory clarify its application. Planned-P2P context remains accurate because
the endpoint does not yet exchange gameplay inputs or construct a mesh session.
Native/Web ownership and receipt invalidation guidance remains in force.
Verify-on-touch: regenerate index/stubs, source/harness lint and self-tests.

## Outcome

State: `findings-acted`.
#31's endpoint criteria are complete; #32/#59 own remaining gameplay and oracle work;
#34–39/#41 retain mesh/browser/client acceptance. Scoped model and endpoint tests
do not establish full-feature parity or supported browser networking.

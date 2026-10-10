# Retrospective: 2026-10-10 protocol and offline example

## Work under review

New bounded packet codec, native/Web vectors, playable driver example and
complete snapshot-read checks. Trigger: new subsystems and review repair.
Evidence: [session log](../../progress/session-008-protocol-and-offline-example.md),
independent reviewers, malformed-state red/green receipts and both engine pins.

## Findings

| Finding | Type | Evidence |
| --- | --- | --- |
| Packet layout and semantic compatibility are separate contracts; epochs and ACKs must survive projection. | Technique | `docs/protocol.md` source audit and independent eleven-message byte/projection goldens |
| Session trailing-byte rejection does not make a callback's state publication atomic. | Technique | Reviewer changed x with a valid prefix plus one extra byte; `session-008-trailing-red.json` failed at byte 24 |
| Reuse the existing exported-Web production gate rather than another launcher. | Technique | `ownership_probes.py` now runs sixteen cases; both pins and the existing precise alias control pass |
| An omission mutant can hide its immediate difference when both snapshots omit the same field. | Technique | `test_offline_example.gd` localizes PRNG/pending omissions to first visible pulse-derived snapshots 21/4, matching schedule 20 and completion 3 |

## Actions taken

| Action | Canonical home | Verification |
| --- | --- | --- |
| Record version separation, field audit and independent production native/Web vectors. | [networking transport skill](../skills/networking-transport/SKILL.md) | Protocol suite and native/Web receipts |
| Check complete reader consumption before applying restored fields. | [session guide](../../docs/session.md), public reader API and load callbacks | Pre-fix failure, post-fix pass and fresh adversarial review |
| Preserve one browser launcher and expand its explicit inventory/source hashes. | `scripts/reference/ownership_probes.py` | Existing receipt self-tests and four native/Web matrices |
| Derive desync localization from serialized consumers instead of assuming immediate detection. | [testing skill](../skills/testing/SKILL.md) | Both pinned offline suites assert first visible saved frames |

## Prune ledger

The networking skill's planned-P1 wording was superseded by the actual codec
contract. Its bootstrap sample remains illustrative; no incompatible second
wire format was introduced. Existing snapshot ownership guidance remains valid;
the public query supplements completion rather than replacing it.
No duplicated knowledge topic or new skill was created.
Verify-on-touch: source/harness lint, regeneration and self-tests pass.

## Outcome

State: `findings-acted`.
Follow-ups: existing #30/#31/#32/#41/#59 own complete protocol/browser integration.
Finite byte-boundary and offline tests establish neither P2P nor release parity.

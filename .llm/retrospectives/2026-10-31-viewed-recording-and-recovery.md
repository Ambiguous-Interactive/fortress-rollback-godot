# Retrospective: 2026-10-31 viewed recording and recovery

## Work under review

Scope: spectator recording-limit feedback, byte-peer driver/expert lifecycle
acceptance, and pinned-source final-receipt observations. Trigger: new capability
and adversarial review correction. Evidence lives in the owning tests, oracle
controls, and machine-local `progress/session-129-playback-driver-boundaries.md`.

## Findings and actions

| Finding | Evidence | Action |
| --- | --- | --- |
| A reusable fixture can make a retained-input witness insensitive to stale values. | `test_peer_session.gd` clamps samples after frame three. Fresh review found the new lifecycle test reused those values through frame eight. | Use changing inputs throughout `test_driver_lifecycle_parity.gd`; a shared stale-sample control now fails independent canonical checks at frame nine. |
| Final traffic counts alone do not prove a missing original input arrived. | The pressure witness drains controls after its last original input was already received. | Observe public source receipt/confirmation frontiers and the exact final original row; physically omit asymmetric final delivery in both changing and neutral controls. |
| A recording cap can be truthful in the API but invisible to the viewer. | Spectator exports stop at 36,000 viewed frames while viewing continues. | Show recorded/omitted viewed counts and a save warning; cross real storage boundaries and decode exports in the scene test. |
| Exported suite registration has three boundaries. | The existing ownership self-test rejected new suites missing from the embedded Web host, despite their copy and expected inventories being present. | Register both suites in every inventory and rerun that exact self-test before exported verification. |

## Guidance and prune ledger

Existing testing guidance already requires changing-input controls, independent
expected events, exact exercised inventories, and alignment of copied, native and
Web suites. Existing oracle guidance requires actual decoded observations and
truthful source differences. These rules were applied at their owning code paths;
no duplicate guidance was added. No stale rule or conflicting fact needed removal.

The upstream source still lacks recovery-only recording after final late input.
The witness preserves its speculative-checksum discrepancy and incomplete export
instead of claiming parity. Broader work remains in #40, #45, #47, #256 and #253.

## Outcome

State: `findings-acted`. No new general rule was needed; the existing regression,
independence and inventory checks found and bounded the evidence weaknesses.

# Retrospective: departure and spectator relay boundaries

## Work under review

Session 069 advances physical RTC departure (#166), spectator SDK ingress
(#131), and corrected status-sensitive replay on native/Web (#45).
New transport integration and external SDK inspection trigger this review.

## Findings and actions

| Finding | Evidence | Action |
| --- | --- | --- |
| Spectators cannot return a game-data negotiation acceptance through the qualified relay. | SDK `dc5302b4` guards and [qualification](../../docs/reference/spectator-relay-qualification.md). | Added the fact to [transport knowledge](../knowledge/transport-tooling.md); the receive-only adapter requires a separate authenticated control path. |
| Existing native replay-after-drop coverage was absent from the exported browser inventory. | [Ownership witness](../../scripts/reference/ownership_probes.py) and [replay drop suite](../../tests/unit/test_replay_drop.gd). | Added all five cases and every-frame original canonical comparisons for both replay interfaces. Existing infrastructure guidance already requires inventory alignment. |
| A physical departure observation must precede all barrier servicing. | Adversarial review of [browser witness](../../scripts/reference/browser/webrtc_drop.gd). | The physical-close gate suspends protocol servicing while the browser closes the departing connections; the browser gate checks held frames and closed resource counts before release. |

| Outstanding expert requests can hide host expiry when stream mutation checks return BUSY first. | Cold review and `busy_deadline` in [adapter tests](../../tests/unit/test_signalfish_spectator_relay.gd). | Added a read-only deadline observation to the stream; the adapter retires expired ownership before buffered delivery or batch commitment. |

| Shared-host execution discarded slow-case isolation, and owner-name equality could mistake another process for the lock owner. | [Regression](../../scripts/tests/test_host_capacity.py) and native identity-suite watchdog evidence. | Kept one worker with case isolation, used acquisition success for ownership, and extended [test infrastructure guidance](../skills/testing/references/infrastructure.md). |

| A passive page-readiness barrier can expire healthy peers even when its own deadline is bounded. | PR193 feedback and [physical witness](../../scripts/reference/browser/webrtc_drop.gd). | Move readiness before quiescence; bound only RTC closure below the real peer timeout. Added the rule to [browser integration guidance](../skills/testing/references/browser-integration.md). |

## Prune and verification

No existing fact was contradicted or duplicated. Kept the established inventory
and physical-resource guidance; recorded the SDK restriction at its existing
knowledge home. Full spectator startup, room/process departure, Firefox/WebKit
release evidence and upstream pinned-drop comparison remain tracked work.

Verification commands and final review/CI outcomes are recorded in the local
session log and linked session PR. No broader release capability is claimed.

## Outcome

State: findings-acted.

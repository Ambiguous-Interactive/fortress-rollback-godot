# Retrospective: Playback and connection recovery

## Work under review

New online replay viewer, offline canonical diagnostic playback, and WebRTC
callback lifetime repair. Trigger: new capabilities and a production lifecycle
bug. Evidence: deterministic native suites, source-bound native/Web ownership
and online exports, and fresh adversarial reviews.

## Findings

| Finding | Evidence | Action |
| --- | --- | --- |
| A close-before-initialize workaround does not make a native callback owner reusable. Late SDP, ICE and channel callbacks require a terminal lifetime fence. | [Connection lifecycle tests](../../tests/unit/test_signalfish_webrtc_engine.gd) reproduce forwarding after close; healthy old controls pass. | Update the existing [transport fact](../knowledge/transport-tooling.md), documenting fresh replacement wrappers. |
| Parallel focused runs can overwrite a full-suite default receipt. | The full-suite stdout passed; subsequent focused runs replaced `latest.json` with a five-case receipt. | Extend [infrastructure guidance](../skills/testing/references/infrastructure.md) to require distinct concurrent result paths. |
| Typed callback results can still contain unbounded byte arrays. | [Malformed checksum controls](../../tests/unit/test_diagnostic_player.gd) exercise zero and 17-byte checksums before report encoding. | Extend [GDScript callback guidance](../skills/gdscript-style/SKILL.md) to validate widths before formatting diagnostics. |
| Captured canonical bytes become actionable when a consumer restores and compares full state, independently of checksum equality. | [Diagnostic tests](../../tests/unit/test_diagnostic_player.gd) compare rolling captures, corrupt state with equal checksum, and callback failures. | Ship bounded playback and the [reproduction command](../../docs/diagnostic-reproduction.md). |
| Library playback is insufficient for users holding a downloaded match file. | [Viewer tests](../../tests/unit/test_replay_viewer.gd) and the [browser witness](../../scripts/reference/browser/online.cjs) exercise import and playback controls. | Add a viewer with bounded imports, preserved failed-import state and checksum stops. |

## Prune ledger

Updated the existing constructor/reinitialization fact rather than adding a
second, conflicting rule. Replaced the online guide's obsolete claim that the
example has no playback controls. Remaining asynchronous SDP, browser matrix,
remote divergence and replay parity acceptance stays in the existing issues.
No new skill was needed; existing lifecycle, callback and bounded-input guidance
already describes the procedure.

## Outcome

Retro: findings-acted

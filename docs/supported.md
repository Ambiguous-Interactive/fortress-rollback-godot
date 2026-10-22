# Supported features

This page states what the shipped addon supports today, what it deliberately
does not, and which evidence backs each claim. It is the supported-release
declaration of [A5](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/44);
the verification tiers and their budgets are in the
[verification policy](verification-policy.md), and the roadmap is in
[PLAN.md](../PLAN.md).

Nothing here promises a published release. A build of the addon candidate
identifies source bytes; the evidence below is what the repository has actually
executed.

## Runtime and platform

| Item | Supported | Evidence |
| --- | --- | --- |
| Godot 4.3 (minimum) | Yes, native and exported Web | Every CI gate that exercises the engine runs both pins |
| Godot 4.7.2 (current) | Yes, native and exported Web | Every CI gate that exercises the engine runs both pins |
| Linux | Yes | CI runs on Linux; the local witnesses are Linux |
| macOS, Windows | Not qualified | Native state-byte equality for those platforms is release work, not done |
| Rust, C#, GDExtension | Not required | The addon is GDScript only; Rust is a development oracle |

## Browsers

| Browser | Supported | Evidence |
| --- | --- | --- |
| Chromium 141.0.7390.37 on Linux | Yes, for the exported WebRTC witness | The exported Chromium witness runs 2/4/8-peer rooms on both pins |
| Firefox | Not qualified | An unrestricted local run passes, but the CI eight-player matrix is still open |
| WebKit | Not qualified | No browser matrix evidence yet |
| Mixed browsers | Not qualified | Same open work as Firefox and WebKit |

## Match scope

| Item | Supported |
| --- | --- |
| Player count | 2 to 8, fixed for the lifetime of a session |
| Input width | 1 to 65536 bytes, fixed for the lifetime of a session |
| Prediction window | 0 to 128 frames |
| Sessions | Local sync-test, external-input, and fixed-membership byte sessions |
| Join and leave | Membership is fixed. A peer that leaves either ends the match or freezes its slot through the coordinated drop barrier |

## Transport

| Path | Supported | Notes |
| --- | --- | --- |
| In-process fake transport | Yes | Development and test fixture |
| SignalFish binary relay | Yes | Bounded queues, recipient filtering, explicit send pressure |
| SignalFish WebRTC direct bytes | Yes | Bounded delivery, packet lifetime fences, server-selected roles |
| Per-peer relay fallback | Yes | Routes unready direct links through the relay and restores ready links in the same session |

The SignalFish adapters are optional. The addon parses and runs without the
SDK installed; a game that uses them supplies the SDK objects described in
[SignalFish membership](signalfish-membership.md).

## Game-facing features

| Feature | Supported |
| --- | --- |
| Driver and expert session API | Yes, with typed statuses and lifecycle errors |
| Input delay increase during a match | Yes. A decrease is refused once the first sample is scheduled |
| Measured input-delay suggestion | Yes, advisory only |
| Deterministic recording and replay | Yes, versioned file format, checksum validation, backward and forward navigation |
| Confirmed-input spectator playback | Yes over a local authenticated byte envelope |
| Bounded diagnostics and desync artifacts | Yes, with downloadable evidence in the browser |
| Graceful peer drop | Yes, with an agreed frozen frame and value across the survivors |

## Explicit exclusions

These are not supported today. Each one names the issue that owns the remaining
work, so a reader can tell an unfinished feature from an unsupported one.

| Feature | Issue |
| --- | --- |
| Live spectator networking over SignalFish | [#131](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/131) |
| Live SignalFish spectator identity and routing | [#47](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/47) |
| Redundant spectator hosts and failover | [#49](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/49) |
| Hot join and session reactivation | [#50](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/50) |
| Transparent reconnect after a disconnect | [#38](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/38) |
| Mixed Rust and Godot wire compatibility | [#30](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/30) |
| ICE restoration, relay congestion and replan handling | [#75](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/75) |
| The Firefox, WebKit and mixed-browser matrix | [#39](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/39) |
| macOS and Windows release evidence | [#44](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/44) |
| Upstream parity for the excluded features | [#13](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/13) |

A release may not advertise a feature that this page does not list as
supported, and the parity ledger must explain every gap.

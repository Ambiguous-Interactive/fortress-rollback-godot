# Retrospective for 2026-11-23

## Work Under Review

Native relay warmup and WebKit close evidence on both Godot pins. Prior hosted profiles stopped at their first failure, sometimes before eight-player relay. One Firefox 4.7.2 warmup failure also exhausted renderer diagnostics.

## Findings

| Finding | Evidence |
| --- | --- |
| A profile can fail before the cell needed for diagnosis. | Hosted WebKit run 45251679399 passed two Godot 4.3 rooms, failed eight-player mesh and emitted no relay receipt. The focused dispatch test exercises the actual Bash arguments and compares the workflow choices with the runner CLI. |
| Lifetime receive counts do not establish liveness near expiry. | The expired Chromium–Firefox pages received more than 1,000 addressed packets each from all seven peers. Chromium–WebKit's expired page received 359. All three still expired before the hold. |
| Timestamp-only reads did not tighten WebKit close bounds. | Isolated Godot 4.3 and 4.7.2 WebKit rooms emitted 237 tagged sends and left seven unproved. Nine smaller serialized reads took 90.570–279.008 ms and recovered zero tags. |
| Packaged Web evidence has a host-specific editor dependency. | The x86-64 hosted archive failed the local ARM64 import with `No GDExtension library found for current OS and architecture (linux.arm64)`. The complete ARM64 archives reached the real browser runs. |

## Actions Taken

- The native qualification workflow can run one explicitly named hosted cell. The default browser profile still covers all eight cells.
- The relay witness records bounded browser, SDK and native enqueue observations using exact tagged bytes. Controller checkpoints preserve evidence when a renderer no longer responds.
- The [transport tooling note](../knowledge/transport-tooling.md) records the measured WebKit window and the evidence needed for another calibration trial.

## Prune Ledger

Dropped the timestamp-only calibration experiment from the candidate after both live runs and exact tag replays failed to show an improvement. Kept the experiment and receipts in local scratch. The roadmap points to the focused dispatch for diagnosis and full profiles for qualification.

## Outcome

State `findings-acted`. Warmup and WebKit proof acceptance remain on #458, #459 and #460. Direct restoration still requires the SignalFish SDK work tracked by #585.

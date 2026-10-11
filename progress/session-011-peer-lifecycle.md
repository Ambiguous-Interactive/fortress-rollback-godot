# Session 011 — Observable peer lifecycle

Goal: make peer stalls, recovery and unsafe game divergence observable.
Base: `9f70110eb91cef8909d0f8acb85901c54304c9f0`.
Branch: `session-011-peer-lifecycle`.
The session PR and linked issues own final head, feedback, merge and main-CI evidence.

## Scope and player behavior

[P4](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/33)
extends the existing byte session and rollback driver. There is no second engine.
Peer sessions enable lifecycle controls by default. Standalone input endpoints
retain their optional input-only configuration.

[Lifecycle controls](../docs/peer-lifecycle.md) expose integer RTT and frame
advantage, pacing recommendations, interruption and resume events, confirmed
game checksum exchange and terminal outcomes. All clocks remain caller-injected.
Valid negotiated traffic refreshes liveness; malformed or stale-era packets do not.
Timers use strict interval equality/+1 boundaries.

Fixed-membership games halt after irrecoverable loss, GOODBYE or desync.
They retain their published confirmation and cannot silently recover after
termination. Create new sessions and synchronize to restart. This differs from
the source's callback and continued drop-player behavior.

Checksum reports carry the complete 16-byte game checksum and saved frame.
Owned checksum metadata avoids copying snapshot payloads. Pending correction
hides affected snapshots until repaired. Sending and comparison use the prior
completed advance's confirmation, rather than a newly received receipt floor.
Mismatch diagnostics preserve peer, frame and both checksums; best-effort
redundant goodbye informs the remaining links.

Publication, pending quality tokens, averaging windows and checksum histories
are bounded. Reserved fatal diagnostics retain actionable terminal causes when
normal event publication overflows. Applications continue polling and draining
all publication queues during a stall.

## Playable witness

The [example](../docs/peer-example.md) shows RTT, frame advantage, interruption,
latest lifecycle event and mismatch frame. Short partitions recover. Long
partitions halt both independent sessions; healing cannot restart them.
R explicitly rebuilds sessions. X changes one peer's game rules to demonstrate
a real checksum mismatch. The fault stays within valid arena coordinates,
including at the right boundary during rollback.

The example tests retain actual bytes, default packet faults, immutable stalled
samples and canonical confirmed-prefix comparisons. Shared comparison boundaries
are clamped to completed game state, even when delivery confirmation is ahead.
The rendered screenshot records actual physical key input on Godot 4.3.

## Actual source observations and scope differences

[The P2P oracle](../docs/oracle-p2p.md) retains all 26 input/ACK scenarios and adds
eight lifecycle cases. Actual public upstream sessions and production Godot
bytes expose quality/keepalive packets, measured RTT, frame advantage, pacing,
interruption/resume/timeout and matching, repaired and mismatching checksums.
Full unsigned-128 source values survive raw JSON serialization and strict validation.

The source's final first desync trigger can return callbacks and outgoing input.
A narrow projection compares its exact trigger and pre-operation state while
retaining the raw continuation. Godot freezes membership at that boundary.
Only the exact owned terminal notification suffix is excluded from comparison.
Earlier triggers, subsequent submitted operations and invented notifications fail.

The source-only zero-window audit advances 14 frames without SAVE requests or
checksum reports. Godot's enabled checksum mode instead requests real saved
lockstep boundaries. This tested extension does not claim source callback parity.
Source network statistics are unavailable before one whole elapsed second;
that raw availability error is preserved, with the API projection documented.

## Review-driven repairs

| Finding | Repair and meaningful evidence |
| --- | --- |
| Running handshake replies failed to refresh keepalive time. | Merge actual handshake send time; clean red and both-pin green endpoint receipts. |
| Retention failure committed resumed state but lost its resume event. | Preserve staged lifecycle events before terminal input failure, without publishing speculative input success. |
| Zero-window checksum exchange produced no reports. | Request real SAVE callbacks in enabled checksum mode; the nonvacuous lockstep test fails before repair. |
| X at the arena boundary created an invalid restorable position. | Keep divergence in the valid coordinate domain; actual fault/rollback regression proves checksum desync. |
| Event overflow retained an interruption but lost the following timeout. | Preserve bounded owned terminal causes per remote peer, including simultaneous local closure. |
| Oracle accepted explicit null lifecycle and invented terminal suffixes. | Strict optional ingress and exact terminal ownership, quantity and policy guards. |
| Controls learned expected diagnostics and coverage could become vacuous. | Declare rejection boundaries independently and require each named case's actual observations. |
| Minimum checksum capacity evicted reports before strict comparison. | Compare retained pairs before eviction; test healthy and divergent window-zero/eight sessions, including outgoing pressure. |
| Malformed nested observer records crashed before structural rejection. | Guard dictionary shape and packet inventory before consumption; subprocess regressions preserve structured exit-two rejection. |
| Named standalone corpus validation skipped source evidence without an expected trace. | Require the expected source trace; valid empty custom traces remain supported. |
| Timeout projection assumed the terminal event occupied the final event slot. | Normalize the identified timeout; unexpected ordered suffixes still fail explicitly. |
| Explicit unknown corpus names silently skipped required coverage. | Reject unknown and empty CLI corpus names before acceptance. |
| Source quality-token projection narrowed valid unsigned-128 values. | Parse the full source width and exercise actual standalone upper-bound packets. |
| Named lifecycle checks accepted a profile without lifecycle observations. | Reject the missing prerequisite before controls consume lifecycle metrics. |
| Full CI suite inherited a 30-second process watchdog. | Set an explicit 120-second full-suite budget; retain focused hang controls. |
| Local close stored the remote-failure reason. | Preserve intentional TERMINATED while genuine event overflow still fails. |
| Terminal poll returned retryable transport backpressure. | Return committed terminal reason; retain recoverable poll/submission pressure. |
| Local close and timeout invented event overflow under packet pressure. | Separate terminal transmission from genuine diagnostic capacity failure. |
| Malformed option types entered typed validators and appeared successful. | Reject invalid public Variant types before validation; verify script-error absence. |

Red/green and independent probe artifacts are under `.cache/tests/` and
`.cache/session-011/`. Final source receipts bind captured source and tool
identities; a concurrent-change attempt intentionally publishes no success.

## Verification and remaining work

Protocol, example, core, oracle and harness fresh adversarial passes are clean,
including both
engine pins, hostile control bytes, arena boundaries, actual rollback and reset.
The core reviewer independently compared every remote in an eight-peer mesh
with checksum capacity one and reversed delivery. The final oracle reviewer
independently compares all eight lifecycle cases on both pins and executes 100
P4 process controls per pin, including six positive wide-token boundaries.
Source files and the rebuilt Rust executable remain stable through publication.
The native/exported-Web inventory includes 70 cases and the intended ownership
alias failures. Clean addon installation exercises 70 gameplay frames, quality
and full checksum bytes, and terminal timeout, with no development tools.

The final frozen snapshot passes all 107 unit cases in repeated fresh processes under
the explicit 120-second CI budget, with complete results across each process's
two deterministic repetitions. Both
determinism suites pass. Six real runner failure/repetition controls pass per pin.
Python gates pass 29 reference tests (two intentional engine skips), 52 oracle
tests and 99 harness tests. Source width, GDScript lint, harness caps, generated
index/stubs, links and `git diff --check` pass.

Final root-owned source commands use
`.cache/reference/editors/<version>/Godot_v<version>-stable_linux.arm64`,
with version 4.3 or 4.7.2:

```sh
python3 scripts/oracle/queue_launch.py --godot <editor> --offline --output <queue-output>
python3 scripts/oracle/launch.py --godot <editor> --offline --output <core-output>
python3 scripts/oracle/handshake_launch.py --godot <editor> --offline --output <handshake-output>
python3 scripts/oracle/p2p_launch.py --godot <editor> --offline --output <p2p-output>
```

Final source receipts live under
`.cache/reference/results/session-011-wrap-<kind>-<version>/`.
Both pins pass all four source gates with unchanged inventories; final full-suite
receipts are `.cache/tests/session-011-wrap-full-<version>.json`. Earlier closure
attempts captured fixture edits and source drift; failed receipts were retained
and no P2P success receipt was published for those attempts. The final API cold
review passes 34 focused cases and 349 independent hostile assertions per pin,
including all combinations of event, packet and transition pressure. Final
harness curation is clean. The linked P4 issue owns final session PR, exact
current-head CI/feedback and merge-triggered main-CI evidence.

Broad long-lived mesh/profile/flood acceptance remains
[P5](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/34).
Real WebRTC/SignalFish transport, browser multiplayer setup and membership repair
remain separate roadmap gates. The broader roadmap remains incomplete after P4.

Retrospective: [artifact](../.llm/retrospectives/2026-10-11-peer-lifecycle.md).

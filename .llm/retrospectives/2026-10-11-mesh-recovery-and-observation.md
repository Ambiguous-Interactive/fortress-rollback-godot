# Retrospective: 2026-10-11 mesh recovery and observation

## Work under review

Continue WebRTC delivery and repair the production exhausted-window gossip stall.
Evidence lives in [session 014](../../progress/session-014-stalled-mesh-recovery.md)
and the deterministic tests linked below. Both are debugging incidents;
the production change also touches prediction and protocol ownership.

## Findings and actions

| Finding | Evidence | Durable action |
| --- | --- | --- |
| A batch barrier can erase timely individual progress for deadline purposes. | The actual-module regression in `scripts/reference/browser/webrtc_watchdog.test.cjs` advances peer 0 at 15 seconds while peer 1 completes at 25 seconds; the original sampler expires peer 0 at 20 seconds. | Extend the existing browser watchdog guidance in [testing](../skills/testing/SKILL.md): apply each completion against its previous individual deadline and rearm current deadlines. |
| ACK drainage can remove the only receipt gossip carrier exactly when the game can no longer submit new frames. | `tests/unit/test_stalled_gossip.gd` exhausts a three/eight-peer prediction window, drains every ordinary input and ACK, then requires unchanged-sample recovery. Pinned Fortress `gossip_holds_confirmation_below_receipts()` specifies this policy. | Keep the conservative remote-evidence fold; provide a bounded acknowledged-input carrier while exhausted and gossip-bound. Record ownership and timer requirements in [networking](../skills/networking-transport/SKILL.md). |
| Green CI does not discharge a known deterministically reproduced defect. | Head `af1c8cd` has green hosted workflows, but #72's actual-module reproduction still fails. | Retain the existing [delivery](../skills/ship-session/SKILL.md) evidence gate. No duplicate rule needed. |
| A recovery carrier can exceed an accepted queue minimum when timers expire together. | Fresh review reproduces `max_transitions = 1` refusing empty-retry plus nudge traces, and enabled `max_outbox = 1` refusing nudge plus quality report forever. | Extend existing networking capacity guidance; coalesce redundant work and defer optional traffic while enforcing lifecycle deadlines. |
| Async rejection does not immediately stop already queued sibling reactions. | Fresh review resolves a sibling in the same turn as timeout rejection; the first repair samples and rearms after failure. The later independent loop adds a pause rejection path with the same extra-microtask risk, including false acceptance. | Deactivate the observation round synchronously on every rejection path; an actual-module ordering table protects the fix. |
| An unset timestamp can overflow elapsed arithmetic at the largest accepted clock. | The fresh public endpoint probe at `INT64_MAX` suppresses the first nudge because `INT64_MAX - (-1)` wraps; the sentinel guard passes both pins. | Extend the existing networking timer rule to require sentinel handling and maximum-clock coverage. |

| Root unit success cannot validate an independently staged native/Web probe. | First pushed CI and the actual offline probe emit 73 cases against an expected 70; three new shared-suite cases were absent from its inventory. | Extend existing testing guidance to align copied cases, selections and preload dependencies; add independent declaration and staging guards. |

| Removing delayed application still leaves delayed resampling behind the same batch barrier. | The actual-module second reproduction rejects a peer advancing every second at 20.15 seconds while its sibling completes within its own deadline; independent loops finish at 19.9 seconds. | Extend the same testing procedure: independent per-page cadence, one in-flight evaluation and a persistent earliest deadline through pauses. |

## Post-merge incident findings

Main's 4.7.2 mesh stalls with fresh observations and live retry service. The
lossless eight-peer control proves that an eight-packet receive budget can lose
to seven input retries plus ACKs while the host permits 32 sends. Pair the
witness budgets and bind the actual host selection to the traffic regression.
Require actual confirmation progress, as a conservative upper-bound assertion
alone also accepts confirmation stuck at -1. Extend existing networking guidance.

Failed-room cleanup erased physical counters needed for diagnosis. Capture them
before destruction with an independent bounded diagnostic that preserves the
original error; actual-main controls protect successful and hung captures.

Overlapping local probes rewrote the same browser installation and caused
ETXTBSY. Unique result directories do not isolate executable extraction. The
existing testing skill now requires serialization of shared bootstrap caches.

The final receipt audit also rejects a counter subtraction across different
service barriers: RTC totals after teardown wait cannot establish FIFO backlog
from an earlier Direct result snapshot. Correct the progress record and retain
the existing same-boundary evidence rule in networking; the deterministic FIFO
test separately measures contemporaneous actual queue depth.

## Prune ledger

Extend existing testing/networking guidance rather than create overlapping skills.
The earlier voluntary input-idle compatibility limit remains distinct from
exhausted-window recovery; correct its scope in the protocol/session guides.
Earlier session 013 receipts remain historical, with their source bindings intact.
The new session log supersedes delivery status only after actual merge/main gates.

## Verification and outcome

Both pinned native engines pass 157 unit cases and eight determinism cases;
the real browser witnesses and 34-case upstream comparisons pass on both pins.
Fresh-context adversarial reviews finish without revisions. Harness lint and
99 self-tests pass. Session 014 records source bindings and local evidence;
linked issues will record the hosted CI and merge gates.
Broader S3–S5 lifecycle/browser and P2P parity requirements retain their issues.

Retro: findings-acted.

# Browser and Network Integration Evidence

Use for actual SDK, exported-browser, lifecycle, scheduling and watchdog witnesses.

Qualify cross-origin control services with actual browser preflight and authenticated fetch.
Native HTTP success does not exercise browser origin enforcement; keep origin permission separate from role capabilities.
Expected provisioning waits use non-error HTTP pending responses; keep actual console/network failures fatal.
Rejected startup also proves zero accepted controls and zero callback invocations; an expected error alone is insufficient.

Integration witnesses must capture every applicable SDK failure signal and
recheck latched errors after the final event drain and before publishing success.
Inject each actual failure signal at that last boundary and require nonzero exit
with no success marker. Correct game state can outlive a late connection failure.

Exercise actual UI controls during playback, after failure and at completion.
Validate displayed state boundaries through every action that pauses playback,
including Step and Pause, not only seeking and cancellation. A departing-boundary
check can leave a corrupt destination displayed until playback resumes.
Controller-only tests cannot prove that visible status and enabled buttons agree.
Cross held interactions with keyboard controls: a drag-start pause must remain owned through refresh, shortcut input and release without movement.
When adding a public status field, update exact browser-result validators and their fixtures together.
Check an actual exported observation too; matching synthetic producers and expectations can both retain an obsolete shape.
Exercise navigation from measured starting frames in both directions; a receipt
named forward can still describe a backward seek. Validate a selected saved boundary
before pausing or canceling; its input may never be advanced. Use the playback
core's bounded snapshot callback so callback/write failures and checksum evidence
follow the same terminal contract as ordinary stepping. Validate every observed control
frontier and nested failure integer, rejecting Python bool/float equality lookalikes.

Bind recorded engine metadata to the verified native engine’s version dictionary, not CLI version text;
those strings have different formats. Validate an actual emitted recording before trusting matching synthetic fixtures.

Replay coverage reports distinguish recorded checksums from comparisons that actually passed.
Exercise absent, sparse and complete checksums, repeated navigation, failed comparisons and restart;
checksum-free playback must never imply verification. Separate host input closure from completed spectator playback.
Exercise missing-input feedback after actual playback as well as at startup; distinguish contiguous gaps from deliberate viewing delay.
To qualify immediate disconnect callbacks, attempt buffered gameplay before explicit adapter polling;
polling can repair a missing callback and hide the lifetime defect. Disable that callback alone as a control.

Engine doubles expose only public methods; verify the real method list and exported interface.
Inspect browser constructor options and resulting properties; ignored options can violate channel policy.
Group dependent browser observers in one init script; separate registration calls do not define execution order.
Retain RefCounted targets when replaying captured old callbacks; select only bindings from the original owner.
Challenge foreign packet rejection at a later clock through the shared session; same-time samples can hide clock mutation.

For network scenarios, compare corrected confirmed prefixes while faults remain
active and assert a nonzero comparison count for every peer. Confirmation can
advance on delivery before predicted game state is repaired; capture actual
callback boundaries rather than assuming the current state is already canonical.
Compare stalled save/load/advance requests too; unchanged frame numbers do not
mean a session performed no work. Do not gate every new input on global
confirmation when receipt gossip requires later submissions. Pace the witness
by endpoint receipts while retaining independent final confirmation and
corrected-prefix checks; otherwise the test driver can create a cyclic wait.
When every peer must exercise rollback, coordinate an explicit predicted step
before delivering its original inputs. A fast clean run can otherwise receive
all inputs before advancing and never restore a snapshot.
Batch bounded transport polls before yielding an exported host render turn.
Delayed-delivery fixtures must check readiness before flushing staged packets;
a successful wait has no render yield. Measure incoming FIFO peaks after every
active delivery boundary, including post-step and final confirmation drains.
Skip final drains when the actual host returns immediately after failed gameplay.
Separate a heavy workload from boundary controls when their combined runtime
exceeds the process cap; preserve every case and repeat layer with distinct receipts.
Limit overlap inventories to the decoded packet/frame domain needed by the proof,
while counting all traffic separately. Late delivery of an early packet stays eligible.
Repeated timer yields per input can make integration duration depend on
software rendering, despite unchanged protocol work; verify under CPU limits.
Keep protocol service active across page-readiness barriers. Recording finalization must also keep
recovery-only receipt publication active after local completion until all participants finish. Quiesce only for the
physical mutation, with controller and page deadlines below the live peer timeout;
verify that agreement starts after closure. Do not hide a long hold by resetting clocks.
Real socket witnesses must measure transport deadlines with elapsed monotonic
host time from the owned handshake epoch. A requested timer delay is not the
elapsed duration of its render turn. Keep game simulation on original frames
and inputs. Exercise handshake retries as well as input loss: an immediate
handshake can hide a missing caller-owned retry token.
Measure rendering or scheduling costs with paired engine/process/CPU controls
before prescribing a viewport or pacing change. A slow turn alone does not
identify its cause. Reject an optimization when its execution contradicts
the prediction; preserve failed receipts and remove unsupported guidance.
Budget real-browser watchdogs for their actual phase and room count. Track
each unfinished peer independently; only monotone game or protocol evidence
may reset inactivity. Keep separate gameplay and confirmation caps and an
absolute room/launcher/job ceiling. Packet counts, stage names and clocks do not
prove progress. Fresh execution must still satisfy every acceptance gate.
Capture bounded physical channel counters before destroying a failed room; keep
the original rejection and bound each diagnostic independently of gameplay.
Prepare shared ZIP tools through verified member comparison and atomic replacement;
never truncate an executable inode held by another process. Exercise preparation
with an actual live executable and a corrupt-cache control. Keep launcher-owned
projects/results and Firefox fresh-tree installation serialized independently.
Apply each page observation at its completion time before waiting for sibling
pages. Check that peer's existing deadline first, then rearm the earliest live
deadline. Exercise asymmetric timely completions and exact expired boundaries;
an all-pages barrier can otherwise discard valid progress against stale clocks.
Observe each page independently with one evaluation in flight per page; slower
siblings must not block its next sample. Keep a persistent earliest-deadline timer
active during inter-sample pauses, and test a fast advancing page behind a valid
slow response that finishes just before its own deadline.
Recheck the monotonic clock after every awaited duration or deadline timer callback;
rearm early callbacks because scheduler delays can truncate. Test just-before and
exact thresholds with an advancing fake clock; a callback does not prove elapsed time.
Deactivate an observation synchronously on every failure path. Resolve a sibling
in the same turn as timeout/evaluation/validation rejection and prove it cannot
sample or rearm after failure; an awaiting `finally` can run too late.
Exercise the lowest accepted checksum capacity through repeated eviction, with
both lockstep and predictive advancement. Require healthy progress and nonzero
actual comparisons for each peer, then inject a real game mismatch at that same
capacity. Retained/send counts alone can pass while every comparison is skipped.

Observe resource construction separately from child creation, so teardown checks
also include abandoned connections that never created channels.

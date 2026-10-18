# Browser and Network Integration Evidence

Use for actual SDK, exported-browser, lifecycle, scheduling and watchdog witnesses.

Integration witnesses must capture every applicable SDK failure signal and
recheck latched errors after the final event drain and before publishing success.
Inject each actual failure signal at that last boundary and require nonzero exit
with no success marker. Correct game state can outlive a late connection failure.

Exercise actual UI controls during playback, after failure and at completion.
Controller-only tests cannot prove that visible status and enabled buttons agree.

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
Serialize probes that reinstall a shared browser or editor cache. Unique output
paths do not isolate executable extraction; overlapping launches can hit ETXTBSY.
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

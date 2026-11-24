# Browser and Network Integration Evidence

Use for actual SDK, exported-browser, lifecycle, scheduling and watchdog witnesses.

When a witness forwards packets to the upstream native binding, allow its
monotonic retransmit clock to run. A tight fake-tick loop can exhaust the
witness before the pinned 200 ms resend window opens after a multi-peer stall.
Keep the sampled inputs and fault schedule tick-based and assert confirmation,
rollback and final state, independent of exact retry counts.

For a mixed-engine mesh that stalls before its first frame, record candidate
categories and the last ICE state before cleanup closes the connections.
If each browser exposes only mDNS host candidates, reproduce the connection
with bare data channels before changing the game or SDK. Firefox can publish
an mDNS name before it registers that name at the start of ICE checks.
Use a STUN-only listener on the host's IPv4 interface to exercise
server-reflexive discovery in the local browser matrix.
Record the listener and verify its UDP Binding response before opening rooms.
[Firefox candidate registration report](https://bugzilla.mozilla.org/show_bug.cgi?id=1605815)

Count startup wait ticks only after the engine reports the full mesh ready.
Retain the earlier browser-open tick count to diagnose event delivery lag.
Require both views to be ready when a direct-only room starts.

Withhold native input datagrams to force a prediction stall while the link
can still carry control traffic. Match each player's quality reply to a report
sent during the hold on the same physical link, then release the original
input bytes. Use a separate full outage to prove expiry.

Qualify cross-origin control services with actual browser preflight and authenticated fetch.
Native HTTP success does not exercise browser origin enforcement; keep origin permission separate from role capabilities.
Expected provisioning waits use non-error HTTP pending responses; keep actual console/network failures fatal.
Rejected startup also proves zero accepted controls and zero callback invocations; an expected error alone is insufficient.
A server can receive authenticated acceptance before the viewer's HTTP acknowledgment settles.
Hold that response after server acceptance and require playback, departure and success to wait while bounded relay polling continues.
Endpoint samples can miss frame advancement queued between evaluation and response fulfillment.
Latch frame changes until the client's successful acknowledgment callback. Allow progress after acknowledgment, even while the response handler still awaits completion.
Validate the HTTPRequest result before parsing its body or accepting HTTP 200; failed requests can contain empty or partial bodies.
A controlled completion-gap repair does not establish the cause of a separately observed aborted browser request.

Integration witnesses must capture every applicable SDK failure signal and
recheck latched errors after the final event drain and before publishing success.
Inject each actual failure signal at that last boundary and require nonzero exit
with no success marker. Correct game state can outlive a late connection failure.
Keep bounded request origin/path, method, resource type, failure code and phase alongside fatal request errors.
Strip URL credentials, query strings and fragments; malformed diagnostic fields must never suppress the original failure.
Preserve those observations when browser operations reject, including later result timeouts; publish one failure artifact before owned cleanup.
If cleanup also rejects, retain both the operation and cleanup causes; test each independently.
Failure reporting must not replace owned-operation errors. Guard reporting and disable custom inspection; test opaque and primitive rejections.
Bounded optional observations may record unavailable metadata. Owned event waits must observe command and event rejections before starting the command.
When a command's reply and completion event can arrive independently, arm the observer before dispatch and settle both bounded operations before reporting failure.
Correlate command receipts to the issuing page and command ID. Record entry and publication on the page clock and receipt on the controller clock.
Test an acknowledgment arriving after a dispatch rejection and require the asynchronous test to reach its final assertion.
Await all owned context and browser closures after sibling rejection, then await server closure. Preserve context-before-browser order for Firefox.
When a cleanup callback contract changes, update every dependent test double and run the complete CI control command, including sibling test files.
Route callbacks run outside the runner's awaited stack. Forward their failures into the same owner and fence every callback continuation before starting another browser action.
A check inside an async wrapper leaves a caller-resumption gap; use lazy action thunks and a synchronous stop check immediately before publication.
Retain started-operation failures observed through owned cleanup and its final event-loop flush. Handle abandoned RPC rejections after failed-owner retirement without resuming work.
Playwright request errors can include authorization headers. Redact capability values in JSON and stderr while retaining raw error identity internally.

Exercise actual UI controls during playback, after failure and at completion.
Assert immediately after each inverse control action; checking only the final state can hide paired unauthorized changes.
Controls that suppress GUI focus to preserve movement need equivalent keyboard actions; exercise both routes through the same ownership gates.
Test numeric shortcuts with differing logical glyphs and physical number-row codes; US key-only events hide AZERTY failures under modifier guards.
Punctuation that requires Shift on another layout needs an unshifted alternative when the handler rejects Shift; exercise that alternative through real GUI routing.
Cross shortcut routing with focused buttons as well as text editors. Godot GUI focus navigation consumes arrow keys before `_unhandled_key_input`; use nonconflicting action keys.
Cross match shortcuts with Ctrl, Alt, Meta, Shift, release and echo events. Preserve intentional shifted punctuation,
such as Plus, and verify that ordinary reset still replaces the match.
After an action changes label height or scene scale, settle layout before measuring the next pointer target.
A press/release across a moving button can miss even when its handler and enabled state are correct.
Before attributing a missed canvas click to browser activation, compare a bounded
pointer press/release across render turns with a trusted DOM control using the same importer.
Return command observations synchronously and check them in the same page evaluation;
a repeated case label can satisfy a readiness wait using stale state from a prior import.
Require a fresh observed effect for each accepted repeated action. Retained export bytes or an earlier success notice
cannot prove that a later Save handler ran; check the export invocation or received-download count too.
Validate displayed state boundaries through every action that pauses playback,
including Step and Pause, not only seeking and cancellation. A departing-boundary
check can leave a corrupt destination displayed until playback resumes.
Controller-only tests cannot prove that visible status and enabled buttons agree.
Cross held interactions with keyboard controls: a drag-start pause must remain owned through refresh, shortcut input and release without movement.
Cross asynchronous file-read success and error completion with held controls and active game requests; native chooser guards do not protect browser callbacks.
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
For a physical route change, sample channel counters after closure at both endpoints.
Require addressed receives on the fallback route and compare inputs first sampled
after the close. A send or a buffered pre-close row can pass a weaker check.
For protocol timeout, defer the resulting physical signaling-socket closes until
all peers report their causes when the first close would trigger a room departure.
Read callback counts at entry to the terminal service tick and after later turns.
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
When a one-time browser gate already emits a console checkpoint, use that
receipt for the controller barrier. Require the original game-state
predicate, one timely receipt per page, and the original deadline.
Start readiness sampling in the same page call that arms a hold. Keep page
clock marks and controller receipt times on their own clocks.
Publish the arm, first readiness and first cap hit while the page runs. Keep
packet and byte counts with each checkpoint so a failed final read keeps its
earlier evidence.
Name the native expiry endpoint in the warmup cutoff while the frozen roster
is available. Match its UUID to retained quality traffic and service samples.
Check roster uniqueness before accepting an endpoint-to-UUID receipt.
Capture interrupted status in the same observation that satisfies the
interruption predicate. Another peer's wait can outlast the first peer.
When a room barrier permits release, save the pre-release snapshot and start
release in one page call. Keep that snapshot available to bounded diagnostics
if release fails. Include the held count at readiness and release to locate
queue growth. Do not make remote handle disposal part of the correction wait.
Use the room's readiness samples for the correction baseline. One peer's
release can correct another peer before its own release snapshot runs.
Retain release and first-correction checkpoints in the controller while the
room is live. A failed final page read can hide even a successful drain.
Bracket the hold with the first held input, matching control reply and
observed prediction stall. Record controller dispatch, evaluation entry and
release start, and compare durations within each clock. Report cumulative
held packets, pending packets and released packets at the cap. A cap can
occur during a partial drain. Retain these checkpoints if the evaluation
never returns.
Emit the history request and publication separately from controller receipt.
Sample a corrected frontier at the end of the physics turn that crosses it.
A rendered snapshot can skip intervening physics turns. If late controller
input raises the target, backfill from bounded page-local observations and
retain the original observation time alongside the console emission time.
For room departure, record the SDK removal and native expiry against the
frozen peer identity before terminal cleanup can erase the causal order.
An advancing browser heartbeat with a stationary Godot turn count locates
a service stall. Missing heartbeats leave the browser or its control path
unobserved.
Match addressed control reports and replies by peer and token, and record
browser send and SDK receive queue peaks in the same phase. If release itself
causes a measured fanout burst, pace the synthetic release in FIFO order while
control traffic continues. Keep the original packet cap and correction deadline.
An inbox acceptance proves delivery to the native queue. A matching outgoing
reply proves that the native protocol processed that report. Keep both marks on
the recipient's clock, and leave the last timeout refresh open when other
traffic could renew it.
Export the requested confirmed prefix once per browser. Keep recurring status
snapshots small. When a page can publish data before its evaluation reply
arrives, arm a page-scoped listener before dispatch. Match the request ID and
frame count and validate the complete receipt within the original deadline.
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

In live rollback witnesses, keep the base history prefix and extend comparison
through samples taken after the observed fault boundary. Bound retained history
and reject a receipt if its comparison cannot cover every endpoint within that
bound. After observing confirmation, require a successful advance before
capturing corrected snapshots.

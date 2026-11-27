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
Set each fake browser's executable variable in the fixture. The local browser environment may otherwise hide failures on tool-free CI.
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
Pair warmup queue counts with the state and frame frontier from the same turn.
Preserve the first valid cutoff and controller receipt across later read failures.
A sample below the gate describes observation. A late receipt describes controller
delivery. Keep optional packet diagnostics independent of the gate.
Start readiness sampling in the same page call that arms a hold. Keep page
clock marks and controller receipt times on their own clocks.
Publish the arm, first readiness and first cap hit while the page runs. Keep
packet and byte counts with each checkpoint so a failed final read keeps its
earlier evidence.
Publish readiness changes immediately. Retain the last waiting sample and
the terminal sample separately. Keep one recent report and reply per link
and direction so a busy link cannot evict a quiet link's observation.
Periodic samples describe traffic at the sampled time. Use native inbox
receipts to establish acceptance before expiry.
Record the warmup expiry endpoint while its roster is frozen. Check uniqueness
before matching the endpoint's UUID to retained quality traffic and service samples.
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
Before expiry cleanup, capture queue depth, last accepted packet and
current and peak Godot service intervals. Expiry may precede the SDK poll.
Use the frozen roster to join the reporter to the sender. Join the sender's
sampled release position by controller receipt order, including equal clock
values. Keep transport acceptance on the reporter's clock.
Capture the first relay overflow inside admission. A pre-tick queue sample
can miss a burst from the next SDK poll. Keep occupied packet and byte
counts, both limits and the refused size. Bracket the SDK call on the same
page clock as the service tick and count admitted envelopes separately
from broadcasts. Test exact FIFO retry after native inbox pressure clears.
Attribute each send at its call site. Unsent packets can remain after a failed
batch. Check both orders of held and passing traffic when the socket closes.
Bracket the hold with the first held input, matching control reply and
observed prediction stall. Record controller dispatch, page entry and release
start. Compare durations within each clock. When a delayed debugger evaluation
consumes the hold budget, prepare one same-origin response per page before
arming. Check every prepared socket before releasing the room. Bound page-side
entry and each deferred batch using the controller's correction deadline.
Keep a separate browser context per page while responses are pending.
The pinned Chromium and WebKit controls admitted only six requests in one context.
Report cumulative held, pending and released packets at the cap. A cap can
occur during a partial drain. Retain these checkpoints if the evaluation
never returns.
Separate the history request, page publication and controller receipt. Keep each timely history when another page fails.
Retain each page's later engine-turn baseline and advancement dispatch and
receipt under the same deadline. Earlier correction progress cannot prove a later turn.
Keep native mesh signaling active through the Leave deadline. Bind the survivor acknowledgments and actual SDK removal to the original Leave command.
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
For exact relay joins, carry the v3 stamp through SDK emission and the relay
FIFO. Key successful steps by room, sender, recipient, epoch and sequence.
Use an absolute binary ordinal to match client send and server ingress on a
single WebSocket, and verify the addressed bytes at each join. Repeated
bytes can earn distinct stamps. Link an echoed quality token to all retained
accepted candidates when their bytes match. Partition retention by directed
link, stage and packet family so unrelated traffic cannot evict the quiet
link. Report omitted records and preserve ambiguous stages. Capture the
same acceptance across quiet-link pressure. For same-link pressure, freeze the
accepted stamp in the gate-resume turn and require raw arrival before gate entry.
Join new sends through raw, check SDK and native absence, and keep original ordinals and full-stream omissions for the selected link.
Release a diagnostic gate on its exact blocked stamps within the page deadline.
Keep one server receipt request outstanding through timeout and match its generation and links.
An on-time open only proves publication when the opened file contains that generation.
For late publication, compare pre-rename server work against the controller window from before request publication.
Order writes by server ordinal and page observations by the recipient's clock.
Stamp validated history synchronously in the console listener with the expiry's controller ordinal.
Await the original failure write before browser cleanup. Bound the wait and handle both the write callback and stream error.
Bind supplemental socket evidence to the acknowledged failure line by digest, with one tagged socket per frozen recipient.
Keep browser source clocks separate from callback times. Recheck proxy coverage after teardown and leave gaps or duplicates unresolved.
Prove ordering between clocks by holding the original socket's FIFO until
both exact raw stamps arrive and the controller reads their successful writes.
Freeze native acceptance in the same page turn as the check. Reuse digests only
for byte-equal copies of the same stamp. Keep every occurrence and hash conflicts separately.
Transfer complete large Playwright receipts as one JSON string and compare all exact stamps to the fixture.
Validate an optional hosted trace cell before setup. Pair stock and trace on the same checkout and room configuration.
Bound OS dependency and browser installs separately. Run generic exported controls before installing additional room-only packages.
Publish the trace build receipt and raw failure logs with the browser artifact.
Export the requested confirmed prefix once per browser. Keep recurring status
snapshots small. When a page can publish data before its evaluation reply
arrives, arm a page-scoped listener before dispatch. Match the request ID and
frame count and validate the complete receipt within the original deadline.
Prepare shared ZIP tools through verified member comparison and atomic replacement.
Exercise preparation with a live executable and a corrupt-cache control. Use a
private Firefox installation when another run can refresh the shared tree.
Apply each page observation at its completion time before waiting for sibling
pages. Check that peer's existing deadline first, then rearm the earliest live
deadline. Exercise asymmetric timely completions and exact expired boundaries;
an all-pages barrier can otherwise discard valid progress against stale clocks.
Retain timely peer receipts, clock brackets, and prior complete proofs on read failure.
Require a complete round for close proof within the shared deadline, with optional calibration off the snapshot retry path.
Publish [close stages and release timing](../../../../docs/native-backend-migration.md#session-boundary) independently of the final page read.
Bracket fetch start, network request start, and response end with controller dispatch, receipt, and handoff. Require the exact HTTP 204.
Firefox can report response start before host write. Keep it for diagnosis. Run stock and each delay on the same runner, preserving every failed attempt.
An interval spanning the required gap is ambiguous. An upper bound below
the threshold proves that the observed send fell short of it.
Keep a bounded receipt for the exact DOM attempt and join it to the engine call only after matching bytes and the frozen reciprocal channel.
Keep entry, DOM send and return on the sender clock. Nested calls invalidate attribution. Engine return codes do not establish browser delivery.
Collect diagnostics in the next bounded snapshot and combine consecutive page observations before returning to the controller.
Keep the cross-page barriers that require every endpoint to pause before the close
and every required link to close before release.
Observe each page independently with one evaluation in flight per page; slower
siblings must not block its next sample. Keep a persistent earliest-deadline timer
active during inter-sample pauses, and test a fast advancing page behind a valid
slow response that finishes just before its own deadline.
Recheck the clock after awaited work, parsing and hashing. Rearm early callbacks.
Use an advancing fake clock to test before, at and after the deadline.
Deactivate an observation synchronously on every failure path. Resolve a sibling
in the same turn as timeout/evaluation/validation rejection and prove it cannot
sample or rearm after failure; an awaiting `finally` can run too late.
Exercise the lowest accepted checksum capacity through repeated eviction, with
both lockstep and predictive advancement. Require healthy progress and nonzero
actual comparisons for each peer, then inject a real game mismatch at that same
capacity. Retained/send counts alone can pass while every comparison is skipped.

Observe resource construction separately from child creation to cover connections that never created channels.
Compare the original history and post-fault samples for every endpoint within
the retention bound. Require a successful advance after confirmation before capturing corrected snapshots.

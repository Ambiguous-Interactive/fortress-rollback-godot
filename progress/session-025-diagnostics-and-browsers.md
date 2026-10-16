# Session 025 — Desync evidence and browser coverage

## Scope and starting state

Started 2026-10-16 at 02:32 UTC; target duration is under two hours.
Main starts clean at `2d34906f4f35b1fb7303c305915682d3fb6af542`.
All three main workflows are green, and there are no open PRs to carry forward.
This session attempts three open user-facing issues: client notifications (#40),
bounded first-divergence evidence (#42), and exported browser coverage (#39).
One session PR will carry the changes through current-head CI, complete feedback
scans, guarded squash merge, local synchronization and merge-triggered main CI.

## Client notifications

`FortressDriver.step_completed(code, frame_before, frame_after)` emits after
ordered request completion and event collection. It reports the final corrected
state for normal steps, repair-only stalls and explicit callback failures.
The driver guard stays active until all handlers return. Recursive advancement
or reconfiguration returns BUSY without another signal. BUSY attempts and
unconfigured drivers emit no completion notice. Peer callers reconcile after
`peer.step` returns so peer control processing also finishes first.

The new notification case fails on the starting revision because the signal is
absent. After implementation, all seven driver cases pass twice in fresh
processes, with in-process repetition, on Godot 4.3 and 4.7.2. Existing stall
coverage now checks one notification after the complete correction batch.
A fresh adversarial reviewer checked all six attack surfaces and reported no
findings. Manual expert batch ownership, expired views, failed callbacks and
notification reentry are exercised. This adds a client convenience under #40;
it does not close that issue's remaining full API/equivalence acceptance.

## Canonical mismatch evidence

A positive `diagnostic_trace_frames` configuration retains bounded owned canonical
SAVE bytes, successful applied inputs and optional application seed/version/replay
metadata. The default captures no payload. Restore invalidates later evidence;
resimulation records corrected input bytes/statuses. A first peer or sync-test
mismatch freezes the window independently of event publication capacity.
Explicit storage reservation and compact JSON bounds account for retained payloads
and bounded metadata. Missing SAVE callbacks or evicted mismatch boundaries stay
explicit; tracing adds no simulation callbacks or remote snapshots.

Seven new cases pass in native tests. They include actual peer mismatches under
saturated events, local snapshot mismatches, caller ownership, independent replay
from captured bytes, strict capacities and exact equality with capture disabled.
A false-positive comparator mutant fails healthy assertions rather than passing
because every game is claimed divergent. A fresh adversarial review found no
remaining issue. Existing exported ownership fixtures now execute these exact
new cases; final source-bound browser evidence follows below.

## Receipt provenance repair (#99)

The original ownership launcher computed repository source hashes only when
publishing success, after copying its exported fixtures. A final formatter edit
while a probe was running exposed that those hashes could name unexecuted bytes.
Four main-boundary controls changed source, staged copy, manifest and imported
helper bytes; all incorrectly published success before repair.

The launcher now freezes source hashes before staging, validates copied authored
bytes, includes imported helpers, and rechecks hashes before publication.
The failed attempt retains logs and removes any prior success receipt.
Fresh review reproduced an unchecked second copy of the checksum sample; a
separate implementer added the relocated-copy control, copied verified staged
bytes, validated its digest and checked exact preload adaptation. All eight
receipt tests pass. Removing the relocated digest check makes its regression
fail. Independent re-review found no remaining issue.

The first exploratory ownership run passed native/Web assertions but is
superseded because its sources changed during execution. A subsequent bootstrap
was safely rejected with ETXTBSY because native tests held the same cached editor.
Final ownership execution waits until those users of the shared cache finish.
The existing testing skill already requires cache serialization; no new rule
was added for this orchestration mistake.

## Remaining delivery evidence

Implementation, browser receipts, final review, CI and merge evidence will be
recorded here or in the linked session PR when those gates finish.

## Firefox display investigation

The first Firefox setup attempts stopped before SDK authentication or RTC setup.
A paired blank-page timing control initially suggested inactive-window throttling;
an automation preference restored those blank-page callbacks but did not restore
the actual exported game's callbacks. That preference was removed.

Actual export failure diagnostics showed the first window stopping at 74 render
callbacks while the second continued through thousands. Signaling opened but the
first game could not resume its SceneTree-timer SDK polling. A paired WebGL
canvas control distinguished fully covered and partly exposed windows:
82→82 callbacks for the covered window versus 3→92 for its sibling; moving
windows apart restored both to 172/182 callbacks over the next 1.5 seconds.
`document.hidden` stayed false, so it was insufficient evidence of activity.

The launcher now identifies each owned Firefox window with a unique temporary
page title before navigation, moves only its unique X11 match, and validates its
display geometry. An 80-pixel horizontal stagger leaves each window partly
exposed. No viewport, game timestep, protocol deadline or gameplay gate changed.
Separate review found NaN/missing geometry passing local setup validation before
the Python receipt rejected it. A separate implementer added malformed-output
controls and lexical/range checks before movement and after positioning.
Nine red cases failed before repair; all sixteen display tests pass afterward.

A real exported 4.3 run then progressed through signaling and mesh creation with
both windows receiving about 3,100 render callbacks over 55 seconds. Both peers
subsequently reported ICE failure and correctly tore down all channels and
connections. This proves the scheduling repair, not Firefox gameplay acceptance.
Candidate/SDP diagnostics and a separate ICE investigation remain in progress.

## Firefox ICE repair (#100)

Standalone default Firefox peers connect with actual mDNS host candidates, so
container privacy settings were not the ICE failure. The browser API control
`session-025-browser-ice-mid.json` contains two NDJSON records: Chromium accepts
an empty media ID, while Firefox rejects it with `No such transceiver`. Both
accept the actual remote SDP media ID. SignalFish relays only candidate bytes
and passes an empty ID with index zero; Godot 4.3 also misspells the browser
index key. The production wrapper now resolves an omitted ID from the actual
remote SDP media section, without changing SDK pins or signaling payloads.

Lookup is bounded to 64 sections, 256 ASCII characters per ID and 65,536 SDP
characters. Explicit IDs and native return codes are preserved. Initialization,
closure, rejected calls and replacement descriptions invalidate old lookup data.
A fresh review found synchronous extension-signal reentry could republish an
obsolete description after close, initialization or nested replacement. A separate
implementer added a revision fence and public-signal red/green regression. All
six focused engine-seam cases pass on both engine pins; re-review is clean.

Godot's synchronous OK means API-call acceptance. Its asynchronous browser
Promise rejection only logs an engine error; the public engine interface has no
completion/rejection signal or remote-description getter. The guide states this
limit. An independent browser control retains the actual old description after
rejecting a replacement. Unsupported asynchronous renegotiation and ICE replacement
remain #38 work; no false success/reset guarantee is claimed here.

The raw-channel negative control now inherits production ICE handling and omits
only channel-option correction. This keeps Firefox from failing at ICE before
reaching the intended policy rejection. Final 4.3 Firefox clean and fault logs
both pass complete 2/4/8-player rooms; the corruption and raw-channel controls
fail at their intended canonical-prefix and channel-policy boundaries. The full
both-engine and mixed-browser receipts remain delivery gates.

## Local verification before push

- Both pins pass 232 unit, four integration and eight determinism cases through
  in-process and fresh-process repetition before the ICE extension. Additional
  final unit/focused runs include its candidate-routing and reentry regressions.
- `.cache/reference/results/ownership.json` passes all four native/Chromium
  positive/negative records. Each executes 87 cases with two in-process repeats;
  native and browser results are exactly equal. All 54 frozen source hashes
  match the current files after execution. The receipt includes real peer and
  local desync evidence, independent replay and opt-in/disabled equality.
- All 82 reference Python tests pass (three environment skips), all 57 browser
  Node controls pass, and all 106 harness tests pass. Source-width and harness
  lint pass. Changed production GDScript and new test suites pass gdformat at 180.
- Fresh driver, trace, receipt, display and ICE reviews are clean after the
  recorded red/green repairs. Browser code review preserves all original gates.

The final browser process remains live while the reviewed candidate is prepared
for one PR. Current-head CI, complete feedback, guarded merge, local sync and
merge-triggered main CI remain required. CI evidence will supplement the local
receipts and bind validation to immutable commits.

## Final source verification and browser diagnostic repair

Both final native unit inventories now pass all 234 cases on 4.3 and 4.7.2,
including the ICE reentry regression, with both repeat layers. The complete
integration/determinism results above remain applicable to the unchanged core.

A later Firefox fallback-disabled control exposed an error in newly added
failure diagnostics: Firefox throws when reading SDP properties on a closed
connection, including the deliberately closed orphan. Both snapshots lost their
otherwise useful failure evidence. The collector now avoids those getters for
verified closed connections and retains null candidate inventories for them.
Active candidate diagnostics remain bounded to sixteen 512-character lines.
A throwing-getter fixture fails before repair; all 57 Node controls pass afterward.
Fresh adversarial review finds no remaining issue. The original watchdog failure,
canonical comparisons and setup/gameplay deadlines are unchanged.

PR #101 initially opened at `2a0fb4929fd769ede0ff596d4adb7ad59649715f`.
The diagnostic repair supersedes that candidate and requires fresh current-head
CI and source-bound browser receipts before merge. Parent issues #39, #40 and #42
now contain precise progress and remaining acceptance. #99 and #100 track the
proven defects repaired by this PR.

---
name: networking-transport
description: "Transport and serialization contracts: bounded WebRTC/SignalFish delivery, fixed-width bytes, versioned traces/replays and checksum domains. Use when touching networking, packets, replays, or desync reporting."
metadata:
  category: feature
---

# Networking Transport

The session logic (see
[rollback-fundamentals](../rollback-fundamentals/SKILL.md)) must not know
whether it is talking to ENet, WebRTC, or a replay file. Everything on the
wire is bytes with an exact, versioned layout.

Peers can finish synchronization independently. Validate early input/control
identity and bodies before discarding them without ACKs, receipts or lifecycle
updates. Test a final handshake reply overtaken by original gameplay on both
direct and relay paths; verify the retried original bytes after later keys change.

Valid foreign session, sender or connection identities must be discarded with bounded
work, owned byte/token release and rejection accounting. Check shared session clocks,
confirmation and control publication too; endpoint rejection alone does not prove
inert facade behavior. Fence SDK callbacks by connection lifetime and nested status/expiry observations by captured session and configuration.

Server-restart witnesses must terminate the owned process handle and verify its
terminal exit. Restart the same verified binary/configuration on the same endpoint;
check the new live handle with bounded readiness. Socket/proxy outage evidence
cannot substitute for process death or a fresh service lifetime.

A replay or spectator format change must update independent consumers and raw packet/
model fixtures as well as the core decoder, oracle and golden. Search magic bytes,
header builders, authentication helpers, version tuples and binary unpack calls;
run the whole consumer suites, since old synthetic fixtures can hide stale formats.
Label failed comparison domains in public diagnostics: an input digest, recorded state
checksum and cached-state comparison can share a byte width without sharing a cause.

For authenticated spectator rows, a refused future frame must not block earlier gap rows
needed to free playback capacity. Retain exact refused bytes and bound scanning across
polls; test one-packet work budgets and multiple blocked rows against original game history.
Keep protocol FIFO requirements separate from this application-level reordering buffer.

## Godot Peer Setup

| Target | Peer | Notes |
| --- | --- | --- |
| Supported browser target | WebRTC plus optional SignalFish SDK | Direct/relay fallback has Chromium pressure and channel-loss evidence; ICE restoration and release matrix remain planned |
| Native validation | Bounded fake transport; WebRTC verified separately | Native availability is not inferred from browser support |
| Development traces | Explicit scheduler and canonical bytes | Injected time and deterministic delivery decisions |

The roadmap does not promise ENet or a fixed channel numbering scheme.
WebRTC inputs target unreliable unordered delivery with protocol redundancy.
Late actual inputs can repair predictions and must remain recoverable until
acknowledged. Binary relay is reliable and can introduce head-of-line delay.
Verify actual SDK channel options; do not infer zero retransmits from packet lifetime.

Optional SDK seams must load every runtime script in an addon-only project and
exercise the real pinned SDK separately through its public transport boundary.
Prove clean-load rejection with an unused runtime script that preloads a missing
SDK resource; exercising only gameplay-reachable scripts misses optional imports.
Compare copied peer-ID algorithms against the actual SDK implementation. Validate
every SDK path that can change mesh authority before SDK consumption, including
additive peer directives after partial connection initialization failure. Plan
validation alone cannot fence those callbacks. Never synthesize public plan notifications
to replay setup. Fence local lifetimes and selected remote participant departures; unrelated roster events remain inert.
A public binary signal without server epoch metadata cannot prove incarnation
attribution; retain that limit instead of treating reconnect tokens as epochs.

For SDK binary relay, keep a drained peer batch caller-owned until atomic adapter
acceptance. Retain the exact FIFO head on send refusal and count owned queues,
socket backlog and receive work separately. Verify retry bytes and corrected
confirmed game state through the actual SDK, rather than counting simulated ticks.
Name injected transport, native server and browser evidence separately.
Prove overlapping delivery with the same packet bytes at physical direct send,
physical direct receipt and addressed relay receipt. An enqueue counter and
unrelated relay traffic cannot prove overlap. Require addressed receipt counts
to fit physical binary receipt totals and the actual remote recipient roster.
Validate the session before counting decoded relay evidence. Bound diagnostic
packet inventories, and distinguish synthetic socket pressure from physical loss.
Validate captured packet headers, declared lengths, INPUT bodies, player/session
identity, connection incarnation and original samples before correlating equal payloads. A captured
retry may contain earlier submitted inputs; validate its actual range rather than assuming the latest frame. Malformed copies
can agree. Parse structured negative-control diagnostics and reconcile their
phase, observed frames and actual deadline instead of accepting a text prefix.
Separate accepted observations from rejected completions; enforce the emitter's
strict expiry and callback-order relationships across peers.
Select a failed direct link by its frozen recipient UUID, not packet bytes: the
same sender input can occur on several outgoing channels. Reconcile source close
initiation with actual events; its own event cannot precede initiation. Distinguish
unreliable-channel loss, engine peer removal and ICE/channel replacement. If an SDK
tears down peers already removed by the engine, verify both dynamic-call removal
branches with actual present/absent engine peers and require clean live teardown.

Fence retained direct bytes with a monotonic local plan/lifetime revision, not
just current opaque generation equality. The SDK can rebuild per-peer channels
while retaining its multiplayer peer, and plans can change A→B→A between service
calls. Same-generation offerer changes can also replace connections. Test queued
outgoing and incoming work across those transitions; repeated identical plans
must not fabricate a replacement. Reserve PacketPeer reads for one consumer and
capture sender/channel/mode before get_packet advances to the next packet.
Inspect actual browser data channels, not just Godot option dictionaries.
Composed path switching preserves terminal SDK failures and lifetime fences before transferring output,
including zero or due fallback grace. Relay availability cannot validate a replaced or failed direct adapter.
Test send/read and prelatched errors through configuration, status, enqueue and polling, separately from retryable busy sends.
Clear a pre-fallback unavailability timer on demonstrated direct recovery, and
observe restoration readiness even during polls without outgoing packets.
Arm refusal timers from the actual refused destination, not an aggregate poll
error: inbound pressure and another peer's refusal do not implicate healthy tails.
A transport that is polled after the SDK hands frames over must drain its
traffic counter in the poll, not difference it at poll entry, or a frame that
arrived earlier is never reported. Count a refused item as traffic: valid work
can sit behind it, and an idle rule that ignores refusals can end a service
batch too early.
Exercise enough refused destinations to exhaust the per-poll attempt budget ahead of healthy links.
Advance the roster cursor after refused attempts too; acceptance-only rotation can starve later links.
Preserve each peer's FIFO and exact bytes while rotating bounded service across polls.
The pinned engine's legacy maxPacketLifetime spelling is ignored by browsers
that expect maxPacketLifeTime. Use the production connection factory correction
and verify the resulting lifetime; do not claim a zero-retransmit policy.

Authenticated startup retries share the payload path’s clock, callback and terminal-lifetime
gates, including outgoing acceptance helpers. Test deadline equality, stopped viewers and active requests;
busy acceptance retries preserve exact bytes after completion; version mismatch cannot terminate through a callback.
Authenticated host liveness and confirmed-input progress are separate observations.
A spectator keepalive may refresh elapsed host expiry without advancing a row,
repairing a gap or affecting player confirmation. Keep deadline equality and
foreign-packet inertness unchanged, and agree support for optional packet kinds.
Discard validated obsolete spectator rows without renewing liveness, including during clean-tail playback; retain conflicts while rows remain in history.
Priority liveness traffic must yield to queued row work. Test repeated keepalives with a one-packet budget;
a one-shot bypass can pass while repeated priority insertion indefinitely resets the receive cursor.
A confirmed-row publisher owns each refused packet until exact transport acceptance;
re-reading the host ring on retry can lose already prepared history. Fence the
host configuration lifetime before returning retained bytes, keep liveness independent
of row pressure, and report an overwritten next row explicitly. A stopped producer still
owes liveness while final rows or END are refused; stop heartbeats only after END acceptance.
Exercise one-send poll budgets: refused payloads and smaller liveness packets need fair
turns across polls, including when only the heartbeat fits the socket capacity.
Preserve retryable session stalls at transport facade boundaries, including finish-host
confirmation or repair waits. A specific peer code does not excuse a terminal outer code.
Input closure is separate from playback termination. After END, test retries while the tail is paused and after its last driver step.
Preserve authenticated conflicts before completion; completed clean END must not map normal termination to peer failure on polling or SDK callbacks.
Cross completion inside control callbacks with queued late traffic; cancellation, host loss and incomplete tails must still fail.
Use the playback completion authority: final-frame equality plus a generic terminal reason can also identify cancellation, even for empty matches.
When a stream exposes its playback session, fence both packet delivery and elapsed
expiry against successful session replacement. Equal configuration values do not
preserve a connection lifetime; rejected configuration must preserve the valid stream.
Successful stream replacement must also retire its prior owned playback session: a retained
driver can otherwise consume buffered rows without calling the stream. Preserve independently
reconfigured sessions by checking ownership identity before termination.
## Serialization Rules

1. All packets are built with `StreamPeerBuffer` in **explicit little-endian,
   fixed-width** form (`put_u32`, `put_u16`, `put_u8`). Never `put_var` —
   its encoding is engine-version-dependent and kills replay stability.
2. The [Godot protocol codec](../../../docs/protocol.md) defines the bounded
   versioned layout. The bootstrap sample is illustrative only.
3. Floats on the wire only if IEEE-exact ops were used end to end (see
   [determinism](../determinism/SKILL.md)); prefer integers.
4. Inputs are delta-compressed only *after* correctness: predictability of
   the byte format beats bandwidth micro-optimizations. See
   [input_serialization.gd](../../code-samples/input_serialization.gd).

## Replay Format

Gameplay replays and diagnostic network traces have separate formats. X1 owns
gameplay replay; there is no released `FRG1` format. The
[development oracle](../../../docs/oracle.md) owns only its scoped sync-test traces.
Preserve revisions, wide values and ordering; version released format changes.
Validate mutable recording dimensions and format before prefix arithmetic or checksum reads. Public row reads also check complete input/status storage before indexing or slicing.
Keep safe missing-digest and content comparisons at their owning playback boundary.
Trimmed recordings use their endpoint's own checksum, never later or absent evidence. Prefix copies must only shrink every backing buffer: padding short checksums, digests, flags, inputs or statuses fabricates exportable evidence. Test partial rows and absent storage.

## Desync Detection

1. The session ADR negotiates an owned 16-byte checksum domain; the sample's
   eight-byte FNV checksum and the oracle game's checksum are separate examples.
2. P4 owns checksum exchange and desync policy; A3 owns bounded diagnostics.
   Compare canonical bytes in verification, since matching checksums are insufficient.
3. Upstream reports `DesyncDetected`. The Godot API's terminal/error behavior
   follows the [session contract](../../../docs/contracts.md); do not invent a
   shipped degraded mode or packet layout from bootstrap guidance.

## What Belongs Here vs Elsewhere

Keep layout version separate from semantic compatibility. Audit every supported upstream message field before choosing a Godot representation;
preserve epochs, ACKs and wide token bytes in the semantic projection. Test independent byte goldens and malformed bodies through the production decoder on native and Web.
Round-trip agreement alone cannot establish field preservation or source parity.

Keep valid remote handshake dimensions, semantic versions and feature masks
parseable within hard bounds; endpoint policy must emit specific mismatches.
The [handshake guide](../../../docs/handshake.md) owns timing and echo policy.
Audit every queued control message's timer effects, then compare actual packets,
events and post-transition observations at strict interval boundaries.
Handle unset timestamp sentinels before elapsed-time subtraction; exercise the
maximum accepted injected clock so signed overflow cannot suppress recovery.
Validate scalar and collection cardinality limits before scanning identities or
allocating lookup tables. Accepted queue minima must permit initialization and
completion after drains, including the maximum configured roundtrip count.
For retained checksum histories, trace scheduling, send-floor advancement,
strict confirmation eligibility, comparison and eviction as one handoff. Accepted
minimum capacity must retain matching local/remote evidence until comparison can
consume it. Successful sends and bounded occupancy do not prove this handoff.
Exercise simultaneous timer expirations at each accepted queue minimum. A
redundant empty-work trace or optional control packet cannot make essential
recovery permanently unpublishable; defer optional traffic without deferring
interruption or timeout decisions.
Retained caller batches never suppress elapsed-time protocol polling. Adjudicate
expiry before servicing buffered receives or SDK lifetime callbacks. Keep due
timeout diagnostics independent of unsent retry state under token or packet pressure.
Cross pressure with full diagnostic banks and an overdue later roster link.
Keep committed operation control separate from the target's gameplay lifetime:
freezing a slot must not discard duplicate commits or their acknowledgements.
Irreversible commit retries outlive negotiation expiry until live survivors acknowledge.
Test lost ACKs across that deadline and quiescence after ACK; match the complete certified operation.
Validate a proposed cut against each receiver's captured receipt inventory, not only its
exposed frontier; a correct proposer algorithm does not validate a broken proposer's candidate.
Freeze the participant set when a local agreement opens. A lost participant before
commit must abort that attempt, not silently reduce its certificate requirement.
Test the same departure before and after commit; only the unfinished attempt aborts.
A final candidate can overtake its donor plan or chunks. Keep incomplete history
unable to certify while awaiting bounded retries; do not terminate merely for
that reordering. Validate every target overlap and suffix capacity before any
target installation, and retain exact donor bytes independently of send pressure.
Cross the smallest accepted publication queue with polling at retry equality.
Control and data yield fairly; consume turns/timestamps only after acceptance. Test fast polling and staggered acceptance without shifting another link's deadline.
Send data after its destination accepts its plan, even while another destination refuses.
Keep conflicting immutable overlaps separate from incomplete coverage. A truthful
shorter certificate is missing history, not conflicting history.
After draining publication space, re-poll before accepting buffered traffic;
service every eligible endpoint despite another endpoint's recoverable refusal.
Every composed façade must expose drains for all bounded publication queues,
including diagnostics. Run healthy sessions past each default capacity. A partial
multi-link publication must consume the accepted clock even when a later link
backpressures. Keep outgoing local receipt gossip separate from incoming peer
observations; confirmation must never count local claims as remote evidence.
Capture receipt status at the compared service boundary. Receiving input before
retrying another link can change its gossip even when frames and ACKs match.
Distinguish voluntary input-idle lag from an exhausted-window gossip deadlock.
When ACKs drain the last input carrier, recover only with bounded fresh remote
status evidence; never substitute local receipt for remote confirmation. Retain
an owned acknowledged sample within configured memory and separate input/nudge
cadence from ACK/control traffic so ordinary heartbeats cannot starve recovery.
Explicit final-history recovery also needs gossip below prediction-window exhaustion.
A sender's local confirmation does not prove every recipient learned its receipt bank;
keep bounded historical carriers eligible while the caller services explicit recovery.

Preserve the inbound FIFO head and its generated handshake token when a peer
returns recoverable queue pressure before committing packet state. The same
code may also accompany terminal event overflow: inspect committed lifecycle
before deciding to retry. Continue bounded outgoing service while incoming work
waits, so pressure cannot starve queued ACKs. Prove both paths using real peers.
Size send and receive work together under polling slower than the retry interval.
An input retry generates an ACK; an eight-peer lossless FIFO can grow when only
send work is raised. Test actual peer traffic, physical backlog and confirmation,
then bind the host's selected budgets to the tested workload.
Validate callback tokens as null or exactly 16 owned bytes before copying. Peer
pressure can occur before protocol token validation; relying on that later
validation can retain an arbitrary callback object or oversized packed array.
Recheck lifetime gates immediately after callbacks, before validating their
return values, so malformed output cannot overwrite a latched teardown failure.
Terminal failure closes signaling as well as game transports; finish close handshakes without servicing gameplay.
Keep callback owners alive while they execute. Logical Leave retires owned game work and bumps its lifetime before SDK close callbacks.
Defer physical Node release while it emits or executes; recheck lifetime after startup polls, getters and setup before continuing.
Test callback Leave as well as failure: cancellation stays offline, without another ADVANCE or a fabricated transport error.
Test physical socket closure before user cleanup; a later Leave can hide leaked connections or membership.
Deferred adapter detach must finish cleanup after unwind; latched failure alone proves no queue or listener release. Recheck channel/socket getters before sending.

Before servicing queued optional-SDK bytes, validate current connection, authentication,
player UUID and frozen room identity through public getters. A close can invalidate
the connection before its signal arrives; a spectator baseline can replace identity.
Committed spectator status failures retire owned buffered playback and queued acceptance; recursive checks and independent replacements stay untouched.
Treat SDK getters and protocol-info conversion as synchronous callback boundaries. Observe lifecycle signals during setup; fence recursive entry, detach and replacement;
keep joint identity/config observations local until revision and failure checks pass. Require stable SDK accessors; repeated reads cannot make arbitrary side effects atomic.
Deferred adapter validation does not pause downstream SDK listeners. Inspect actual consumers; refuse unsafe synchronous reentry before they consume it.
A known-member reconnect requires a new rollback lifetime when the SDK omits the server epoch. Prove refusal with a valid queued packet and no outgoing work.

Audit committed lifecycle state against published events on callback failure,
including a retained input prefix followed by refusal. Preserve accepted liveness
transitions before terminal failure; exclude speculative input-success events.
Normalize exported event metadata by type as well as field name. A reason can
contain nested roster IDs or input bytes; export only bounded scalar tags.
Capture the terminal cause when lifecycle commits, before any public event drain. Collect diagnostics only after verified termination or physical teardown.
Awaited downloads can advance a live witness beyond its retained-history bound.
Reserve bounded fatal diagnostics independently of normal event capacity. Fill
the reserve with a recoverable overflow first, then inject terminal events from
every remote link. Each actual fatal cause must survive with owned peer metadata;
halting simulation alone does not prove diagnostic preservation.

Size per-peer limits against the remote's resources too. A queue for a remote slot spans that
remote's delay, the local delay and two prediction windows; a local-only check let two peers at
the limit overflow each other. Any API that emits frames outside `step` must resume each endpoint
from its own `last_submitted_frame`: a backpressured step leaves the core one sample ahead.
A limit that bounds what one peer sends another must be agreed or exchanged in the handshake.
Refuse a mismatch when it shapes the session (`queue_capacity`). Send to the smaller value when
peers may differ (`max_packet_bytes`). Check received batches against the protocol maximum, never
the local send cap (`max_input_frames`). An unagreed cap fails later as a silent stall.

- Wire formats, channels, replay layout, checksum exchange: this skill.
- When to roll back and why: rollback-fundamentals.
- Bit-exactness of what you serialize: determinism.

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

## Godot Peer Setup

| Target | Peer | Notes |
| --- | --- | --- |
| Supported browser target | WebRTC plus optional SignalFish SDK | Direct/relay fallback has live Chromium pressure evidence; physical recovery and release matrix remain planned |
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
to replay setup. Fence membership and transport-lifetime changes explicitly.
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

Fence retained direct bytes with a monotonic local plan/lifetime revision, not
just current opaque generation equality. The SDK can rebuild per-peer channels
while retaining its multiplayer peer, and plans can change A→B→A between service
calls. Same-generation offerer changes can also replace connections. Test queued
outgoing and incoming work across those transitions; repeated identical plans
must not fabricate a replacement. Reserve PacketPeer reads for one consumer and
capture sender/channel/mode before get_packet advances to the next packet.
Inspect actual browser data channels, not just Godot option dictionaries.
Composed path switching must preserve each adapter's terminal lifetime fences
before transferring output, including zero or already-due fallback grace periods;
relay availability cannot turn a replaced direct transport into a valid lifetime.
Clear a pre-fallback unavailability timer on demonstrated direct recovery, and
observe restoration readiness even during polls without outgoing packets.
Arm refusal timers from the actual refused destination, not an aggregate poll
error: inbound pressure and another peer's refusal do not implicate healthy tails.
Exercise minimum routing work with a blocked peer ahead of a healthy peer;
bounded work alone does not prove fair service. Preserve each peer's FIFO while
rotating service across the frozen roster.
The pinned engine's legacy maxPacketLifetime spelling is ignored by browsers
that expect maxPacketLifeTime. Use the production connection factory correction
and verify the resulting lifetime; do not claim a zero-retransmit policy.

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

Confirmed gameplay replays and diagnostic network/scenario traces are separate
formats. X1 owns the gameplay replay format; there is no released `FRG1` format.
The [development oracle](../../../docs/oracle.md) defines its scoped sync-test
scenario/trace version. It does not define protocol packets or gameplay replay.
Preserve revisions, wide values and exact ordering; reject unsupported versions.
Never change a released format silently.

## Desync Detection

1. The session ADR negotiates an owned 16-byte checksum domain; the sample's
   eight-byte FNV checksum and the oracle game's checksum are separate examples.
2. P4 owns checksum exchange and desync policy; A3 owns bounded diagnostics.
   Compare canonical bytes in verification, since matching checksums are insufficient.
3. Upstream reports `DesyncDetected`. The Godot API's terminal/error behavior
   follows the [session contract](../../../docs/contracts.md); do not invent a
   shipped degraded mode or packet layout from bootstrap guidance.

## What Belongs Here vs Elsewhere

Keep layout version separate from semantic compatibility. Audit every supported
upstream message field before choosing a Godot representation; preserve epochs,
ACKs and wide token bytes in the semantic projection. Test independent byte
goldens and malformed bodies through the production decoder on native and Web.
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

Before servicing queued optional-SDK bytes, validate current connection, authentication,
player UUID and frozen room identity through public getters. A close can invalidate
the connection before its signal arrives; a spectator baseline can replace identity.
A known-member reconnect requires a new rollback lifetime when the SDK omits the
server epoch. Prove refusal with a valid queued packet and no outgoing work.

Audit committed lifecycle state against published events on callback failure,
including a retained input prefix followed by refusal. Preserve accepted liveness
transitions before terminal failure; exclude speculative input-success events.
Reserve bounded fatal diagnostics independently of normal event capacity. Fill
the reserve with a recoverable overflow first, then inject terminal events from
every remote link. Each actual fatal cause must survive with owned peer metadata;
halting simulation alone does not prove diagnostic preservation.

- Wire formats, channels, replay layout, checksum exchange: this skill.
- When to roll back and why: rollback-fundamentals.
- Bit-exactness of what you serialize: determinism.

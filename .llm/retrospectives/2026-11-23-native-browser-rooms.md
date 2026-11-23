# Native browser room qualification

## Findings

- Both hosted Chromium pins passed seven of eight rooms. The eight-player relay rooms released their held packets, then one or more native peers expired.
  A pinned three-CPU reproduction at 1280×720 hit the same failure and recorded a 2,109 ms gap before one endpoint expired.
  At 480×360 the witness compared 40 frames and the longest observed interval between native queue acceptances was 1,182 ms.
  The smaller hosted fixture still expired on both pins. Hold input packets during recovery and verify that real control traffic continues.
  Keep the previous full link outage in the terminal case.
- Firefox also hit Godot's 65,535-byte WebSocket buffer during warmup, below the SDK's 262,144-byte soft cap.
  A 1 MiB engine buffer removed all eight hard-limit errors on the matched three-CPU run.
  With selective input holding, the same Firefox room compared 40 frames and every peer received 160 or more control packets during the hold.
- Chromium–Firefox could lose links before gameplay at eight peers. The actual exported room delivered all 140 signaling messages.
  The bare eight-peer control opened 44 of 56 endpoints when Firefox's early mDNS candidates arrived before Firefox applied the answer.
  Applying them after the answer opened all 56. A STUN-only listener on the host interface also opened all 56 with early delivery.
  It gave Firefox a server-reflexive candidate. Loopback STUN left Firefox with host candidates only.
  [Firefox candidate registration report](https://bugzilla.mozilla.org/show_bug.cgi?id=1605815)
- WebKit reported a send failure when a peer deliberately left. A browser-only reproduction showed the JavaScript call returning normally while the remote SCTP stream closed.
  The eight-player run also observed aborts as survivors closed their links to one another. WebKit reports the failed send on its JavaScript call stack.
  Tag the sending channel and match the reciprocal close. After departure, require a terminal room participant and a new SCTP abort on that link
  or a recorded peer close before the tagged send. The sender's local teardown can win the race with the abort callback.
  During a planned stream close, require both ends closed and the nominated closer. WebKit can report the send failure without an SCTP abort in that case.
  [Pinned WebKit diagnostic](https://github.com/WebKit/WebKit/blob/56453fdfe0b0ca6258c23e6453b34f70b885d13f/Source/WebCore/Modules/mediastream/RTCDataChannel.cpp#L67-L85)
- Fresh review found that TCP readiness accepted a stand-in without UDP STUN, and a pending diagnostic could stall cleanup.
  The controls rejected the stand-in and bounded the blocked renderer while still closing the browser and listening socket.
- The hosted WebKit profiles found three browser-open ticks before the engine began some direct matches.
  Those matches had complete meshes, no relay sends, and confirmed gameplay. The startup receipt now distinguishes browser-open time from engine readiness.
  The two-tick guard measures only waits after both views report the full mesh ready.

## Prune ledger

The [native migration contract](../../docs/native-backend-migration.md) links the playable browser procedure alongside the earlier Rust interoperability experiment.
The [browser testing guide](../skills/testing/references/browser-integration.md) explains how to distinguish mDNS candidate loss from a gameplay stall and verify the STUN fixture.
Both Rust crates now inherit the same formatter configuration at the repository root.

## Outcome

The witness shares the gameplay assertions across browser profiles. It records browser identity and packet hold duration per peer and rejects incomplete room receipts.

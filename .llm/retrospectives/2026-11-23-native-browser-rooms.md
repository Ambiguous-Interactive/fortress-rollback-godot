# Native browser room qualification

## Findings

- Both hosted Chromium pins passed seven of eight rooms. The eight-player relay rooms released their held packets, then one or more native peers expired.
  A pinned three-CPU reproduction at 1280×720 hit the same failure and recorded a 2,109 ms gap before one endpoint expired.
  At 480×360 the witness compared 40 frames and the longest observed interval between native queue acceptances was 1,182 ms.
- Chromium–Firefox could lose links before gameplay at eight peers. The actual exported room delivered all 140 signaling messages.
  The bare eight-peer control opened 44 of 56 endpoints when Firefox's early mDNS candidates arrived before Firefox applied the answer.
  Applying them after the answer opened all 56. A STUN-only listener on the host interface also opened all 56 with early delivery.
  It gave Firefox a server-reflexive candidate. Loopback STUN left Firefox with host candidates only.
  [Firefox candidate registration report](https://bugzilla.mozilla.org/show_bug.cgi?id=1605815)
- WebKit reported a send failure when a peer deliberately left. A browser-only reproduction showed the JavaScript call returning normally while the remote SCTP stream closed.
  In the exported run the survivor then reported an SCTP close abort and its callback counts froze. The receipt retains the exact diagnostic and requires the physical abort.
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

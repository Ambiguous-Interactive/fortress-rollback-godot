# Qualifying native startup and relay after channel loss

## Change

The native online example gives a direct mesh three seconds to connect before
starting synchronization on a partial mesh. The frozen plan provides endpoint
identity. The existing coordinator sends each unavailable link through relay.
The legacy backend still requires a full direct mesh at startup.

## Findings and actions

- The Godot 4.3 red export closed one negotiated channel on both endpoints
  before either channel opened. All four pages finished at frame 0 with no
  game callbacks. The two affected pages never started the fallback
  coordinator because the lobby required every direct link to connect.
- Immediate native startup reached frame 40 on the same fault schedule, but
  the probe showed 200 and 218 relay sends on the two unaffected pages while
  direct negotiation was still pending. Giving the direct links time to
  connect kept startup relay on the target pair.
- A grace check on 4.7.2 measured 2,988,270 µs for the creator and 3,000,115 µs
  for its peer. The creator reused the deadline from its Start button.
  Every peer now measures grace from its first accepted mesh-plan attempt.
- Review found two gaps in the browser receipts. The probe now observes
  addressed relay receives, reads healthy direct counters after both sides
  close, and requires compared input samples generated after the close. It
  records callback entry counts at the beginning of the failure tick, then
  compares them after later ticks.
- The pinned SDK drops a peer entry when a negotiated channel closes. That
  leaves no connection to receive a new offer for the same room and plan.
  [SDK #585](https://github.com/Ambiguous-Interactive/signal-fish-client-godot/issues/585)
  owns same-room replacement. The
  [WebRTC closing and opening procedures](https://www.w3.org/TR/webrtc/#closing-procedure)
  establish why the old closed channel cannot qualify replacement.
- The [browser testing guide](../skills/testing/references/browser-integration.md)
  now requires receive-side route evidence and callback counts at the terminal
  tick. The fixture defers only the game's resulting physical socket close.
  This lets every peer independently reach the upstream timeout before SDK
  departure could end the others. Godot 4.7.2 clears its receive buffer when
  it calls close. The fixture retires the message handler at that point to
  keep late signaling out of the cleared buffer while the socket stays open.

## Prune ledger

The [native setup guide](../../docs/online-example.md#try-the-native-backend)
now describes the partial-mesh fallback. It replaces the former requirement
that every direct link connect before native synchronization begins.

## Outcome

findings-acted

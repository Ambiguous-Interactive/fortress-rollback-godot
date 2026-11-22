# Qualifying the native driver in the online example

## Work under review

The opt-in driver uses the pinned upstream session and the existing game
callbacks. Exported SignalFish rooms exercise the playable scene over direct
WebRTC and relay. The stock UDP peer still exercises the raw compatibility API.

## Findings and actions

- An unpaced three-peer packet witness exhausted its 500 ticks before the
  pinned 200 ms protocol retry. Its report froze at frame 14 on two endpoints.
  Pacing network service let all layouts confirm through frame 47. The
  [browser and network witness guide](../skills/testing/references/browser-integration.md)
  records the distinction between the protocol clock and the input schedule.
- The first WebRTC room refused to freeze when its four-byte profile inherited
  a one-byte neutral sample. The match now sets the neutral width with the
  profile. The exported witness goes through room admission and Ready.
- Fresh review found that terminating from a game callback left the active
  view readable or writable until the callback returned. The driver expires
  the view in the terminal transition. Removing that expiry produces
  `callback termination did not expire the active save view` in the
  [native qualification script](../../scripts/qualify_native_driver.gd).

## Prune ledger

Replaced the GDScript-only project description in [agent context](../context.md)
with the opt-in backend boundary. The shipping limit stays in the
[migration contract](../../docs/native-backend-migration.md).

## Outcome

findings-acted

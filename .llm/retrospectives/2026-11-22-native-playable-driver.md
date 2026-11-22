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
- Godot's parser treats added optional arguments as signature changes.
  The local Gate identified three legacy transport subclass overrides that
  stopped compiling. Native transport setup now has its own entry points, and
  the [style skill](../skills/gdscript-style/SKILL.md) directs earlier validation.
- Godot 4.7.2 filled its 64 KiB WebSocket receive ring in an eight-player
  relay room. The pinned relay broadcasts each datagram to the room before
  clients filter it by recipient. Increasing the SDK drain budget alone still
  left 3,922 engine drops. Configuring the socket's bounded 1 MiB receive
  ring before connect let the same room compare 40 confirmed frames and
  stop all seven survivors after departure.
- The runtime archive rejected the new driver's GDScript adapter because its
  explicit inventory omitted the file. The inventory now includes the adapter
  and continues to exclude native binaries.
- A full native receive queue originally took the same route as an invalid
  packet. The real relay adapter dropped the oldest datagram in a saturated
  queue instead of retrying it. The result now separates these cases and a
  startup suite verifies exact-byte retry after capacity returns.
- The corrective termination control saves frame 7 while the driver still
  publishes frame 13. It compares the failure frame to the callback's frame
  and independently checks that the published frontier stays at 13.

## Prune ledger

Replaced the GDScript-only project description in [agent context](../context.md)
with the opt-in backend boundary. The shipping limit stays in the
[migration contract](../../docs/native-backend-migration.md).

## Outcome

findings-acted

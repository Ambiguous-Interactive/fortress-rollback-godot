# Changelog

## [Unreleased]

### Added

- Add a playable offline sync-test example with complete integer snapshots and rollback-safe presentation.

- Add complete snapshot-read checks so callbacks can reject trailing bytes before restoring game state.

- Add bounded versioned protocol messages for handshake, inputs, acknowledgements, timing and checksums. P2P sessions remain planned.

- Add local sync-test sessions, bounded snapshot history, ordered rollback requests, and a synchronous game driver. Networked P2P sessions remain planned.

- Add a bounded raw input queue with owned bytes, frame delay, and repeat-last prediction.

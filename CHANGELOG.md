# Changelog

## [Unreleased]

### Added

- Add fixed-membership byte sessions for 2–8 player slots with retained input retries, cumulative ACKs and mesh confirmation. Applications supply delivery and drain bounded outputs.

- Add a playable two-peer packet-loss example with prediction stalls and recovery.

- Add bounded peer handshakes with explicit configuration mismatch events, injected time and tokens, retries, and synchronization progress.

- Add a playable offline sync-test example with complete integer snapshots and rollback-safe presentation.

- Add complete snapshot-read checks so callbacks can reject trailing bytes before restoring game state.

- Add bounded versioned protocol messages for handshake, inputs, acknowledgements, timing and checksums.

- Add local sync-test sessions, bounded snapshot history, ordered rollback requests, and a synchronous game driver.

- Add a bounded raw input queue with owned bytes, frame delay, and repeat-last prediction.

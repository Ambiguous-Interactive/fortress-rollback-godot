# Runtime attribution

This GDScript addon implements rollback behavior from
[Fortress Rollback](https://github.com/wallstop/fortress-rollback), a fork of GGRS,
at revision `f13cd5c0f2815926785a395947e18da0dbea0dd8`.
Queue and session algorithms were adapted to owned fixed-width bytes, bounded
snapshot callbacks and explicit request completion in Godot. The addon contains
no upstream Rust source or binary dependency.

Fortress is available under MIT or Apache License 2.0. This distribution uses
the MIT option and includes its [original notice](licenses/fortress-LICENSE-MIT).
The GDScript implementation uses the repository's [MIT license](LICENSE).
No SignalFish SDK/server source is included.

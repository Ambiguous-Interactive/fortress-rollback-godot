# Research: fortress-rollback -> GDScript Port Notes

Living document. Facts about the upstream Rust crate and how they map to the
Godot port. Verify claims against upstream before relying on them; mark
unverified items with TODO.

## Upstream Facts (fortress-rollback v0.11.x)

- Fortified fork of `ggrs` (GGPO-inspired P2P rollback netcode).
- `#![forbid(unsafe_code)]`; panic-free API design (`Result`-returning
  session methods; e.g. error handling audited around `advance_frame`).
- Determinism tooling: `BTreeMap`/`BTreeSet` everywhere, no hidden entropy,
  TLA+ specs, Kani model checking, Z3.
- Scale: ~1600-2200 tests, ~92% coverage (upstream README, 2026).
- A Godot-relevant probe exists upstream: `tests/godot-emscripten/` runs a
  Godot 4.6 GDExtension build of the crate under Playwright/WASM. This repo
  supersedes that probe with a **pure GDScript** port: no Rust, no
  GDExtension — same wire/state semantics re-implemented in GDScript.

## Concept Mapping (Rust -> GDScript)

| Upstream concept | Port decision | Skill |
| --- | --- | --- |
| `BTreeMap`/`BTreeSet` ordered iteration | Sort keys explicitly before every state walk / serialization | determinism |
| `Result<T, E>` panic-free | Error codes + `push_error`; no `assert()` for runtime checks | gdscript-style |
| Session event channels | Typed signals emitted at tick end | rollback-fundamentals |
| `serde` state snapshots | `StreamPeerBuffer` fixed-width serialization contract | networking-transport |
| Golden wire-format tests ("wire-golden-immutable") | Replay fixtures with recorded checksums | testing |
| Invariant pre-commit hooks (e.g. `check-advance-frame-error-handling`) | Meta-lint equivalents live in `scripts/llm/` for harness invariants; sim invariants get their own gdscript-side checks once code exists | llm-harness |
| TLA+/Kani/Z3 proofs | Not portable; replaced by property-style determinism tests (run-twice, replay, seeded fuzz) | testing |

## Port Risks (hypotheses to validate early)

1. **Float accumulation**: GDScript floats are 64-bit; `+ - * /` are IEEE
   and source-ordered, but any library call touching libm (trig, pow) is a
   cross-platform hazard. Validate with a Linux-vs-macOS checksum sweep
   before the first networking alpha. (determinism)
2. **Physics engine**: Godot physics is not deterministic across platforms;
   the sim must be custom kinematic integration. (determinism)
3. **Dictionary ordering**: insertion-ordered in GDScript — safer than a
   HashMap, but state walks must still sort explicitly to survive future
   refactors. (determinism)
4. **Web export**: `WebRTCMultiplayerPeer` only; ENet paths need a
   transport abstraction from day one. (networking-transport)
5. **Engine-version pinning**: replays and checksums are only as stable as
   the Godot version; pin the editor version per release line and record it
   in replay headers. (networking-transport)

## Sequencing Hypothesis (to be validated, not a promise)

sim core (tick, state, checksum) -> determinism test suite -> session
(save/load, prediction, rollback) -> local two-peer integration -> transport
(ENet) -> WebRTC -> presentation. Determinism tests gate every later stage.

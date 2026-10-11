# Fortress Rollback Godot

A **GDScript-only port** of [fortress-rollback](https://github.com/wallstop/fortress-rollback)
— a fortified, deterministic, GGPO-inspired rollback networking library — targeting
**Godot 4.x**.

> [!WARNING]
> This project is in an early development phase. Local sync-test sessions and
> an external-input rollback core are implemented. Fixed-membership byte sessions
> include bounded input exchange and rollback. Optional SignalFish binary relay
> is implemented; direct WebRTC and browser release validation remain planned.

## AI-Assisted Development Notice

This repository is developed with heavy AI-assistance and carries a generic
**agentic harness** (inspired by
[unity-helpers](https://github.com/wallstop/unity-helpers)):

- Every agent front-end (Claude Code, Codex, Copilot, OpenCode, Cursor,
  Gemini CLI, Windsurf, Cline, ...) reads a **thin pointer file** that
  delegates to a single canonical context document.
- The canonical context and all skills live under [`.llm/`](./.llm/context.md).
- Skills follow the open [Agent Skills](https://agentskills.io) `SKILL.md`
  standard, with generated discovery stubs under `.claude/skills/` and
  `.agents/skills/`.
- Every file in the harness is capped at **300 lines** (hard limit), enforced
  by tests, git hooks, and CI.

See [`.llm/context.md`](./.llm/context.md) for the full operating manual.
[GitHub operations](./.llm/skills/github-operations/SKILL.md) use authenticated
MCP first and authenticated `gh` CLI for capability gaps.

## Quick Start

Run the [offline example](./docs/offline-example.md) with Godot 4.3 or newer:

```sh
godot --path . res://examples/offline/offline.tscn
```

Move the two players with WASD and the arrow keys. The example uses the shipped
driver and complete integer snapshots while sync-test repeatedly rewinds gameplay.

Run the [packet-loss example](./docs/peer-example.md) with two independent byte sessions:

```sh
godot --path . res://examples/peer/peer.tscn
```

Move players with WASD and the arrow keys. Toggle packet loss, reordering or a
partition to observe prediction stalls and recovery. Delivery runs in process.

Contributor tooling:

```sh
# Install git hooks (blocks commits that break the harness)
make hooks

# Validate the entire .llm harness
make lint-llm

# Run the harness self-tests
make test-llm

# Regenerate the skills index + agent discovery stubs
make llm-index
```

## Implementation and verification

[PLAN.md](./PLAN.md) defines the roadmap and supported product contracts.
[Reference baseline](./docs/reference/README.md) documents verified source/tool
pins and reproducible upstream/native/web probes. The
[interface ADR](./docs/contracts.md) and [evidence policy](./docs/verification-policy.md)
define the next implementation gates. These development artifacts do not imply
that a supported browser release is available.

The [session guide](./docs/session.md) documents the shared expert engine,
bounded snapshots and thin game driver. The [raw input queue](./docs/input-queue.md)
provides bounded per-player history.
The [protocol codec](./docs/protocol.md) specifies bounded binary messages for
the byte session layer, with independent native and exported-Web vectors.
The [fixed-peer handshake](./docs/handshake.md) consumes those bytes, validates
agreement and peer identity, and reports synchronization progress or specific
mismatches. Protocol time and request tokens come from the caller.
The [byte session guide](./docs/peer-session.md) connects that handshake,
[bounded input exchange](./docs/input-exchange.md) and the shared game driver.
The application selects delivery and drains bounded packet/event/diagnostic queues.
The [optional SignalFish membership seam](./docs/signalfish-membership.md) freezes
room UUIDs into stable player slots and validates SDK plans before mesh setup.
The [SignalFish relay adapter](./docs/signalfish-relay.md) delivers opaque binary
packets with bounded queues, recipient filtering and explicit send pressure.
Direct WebRTC and real browser transport validation remain separate gates.
Run `make test-godot` for unit tests or `make queue-probes GODOT=/path/to/godot`
for direct pinned Rust/Godot queue comparisons. `make handshake-probes` compares
actual upstream handshake observations with the Godot endpoint.
`make p2p-probes` compares real upstream sessions through packet faults. Rust is development-only.

## License

[MIT](./LICENSE)

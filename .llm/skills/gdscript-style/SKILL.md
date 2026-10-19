---
name: gdscript-style
description: "GDScript 2.0 conventions for this repo: static typing, naming, signals, autoload policy, error handling, file layout. Use when writing or reviewing any GDScript file."
metadata:
  category: feature
---

# GDScript Style

Boring, typed, reviewable GDScript. The reference formatter is `gdformat`
(gdtoolkit); if a formatting debate starts, the formatter wins.

## Typing

- **Static typing everywhere**: parameter types, return types, typed arrays
  (`Array[int]`), typed dictionaries where available. `Variant` needs a
  comment explaining why.
- Prefer `class_name` for anything reused; keep one class per file and name
  the file after the class (`session_events.gd` holds `class_name
  SessionEvents`).
- Headless test runs skip the editor import, so `class_name` is not global.
  Reference other scripts through `preload` constants. A script builds its own
  instances with `get_script().new()` and returns `RefCounted`, not its own name.
  On Godot 4.3, `PackedByteArray([...])` is not a constant expression; use a
  `String` constant and convert it at runtime.
- Use `@onready` (not `_ready` assignments) for node refs; prefer `%` unique
  names over long `get_node("A/B/C")` chains.

## Naming

| Thing | Convention | Example |
| --- | --- | --- |
| Files | `snake_case.gd` | `input_serialization.gd` |
| Classes | `PascalCase` | `RollbackSession` |
| Functions/variables | `snake_case` | `advance_frame` |
| Constants | `CONSTANT_CASE` | `MAX_PREDICTION_FRAMES` |
| Signals | `past_tense` | `frame_rolled_back`, `desync_detected` |
| Booleans | `is_/has_/can_` prefix | `is_predicted` |

## Architecture

1. **Autoloads are guilty until proven innocent.** An autoload is hidden
   global state: it breaks determinism-by-construction (tests can't isolate
   it) and replay (state not captured). Allowed for: logging/UI facades.
   Forbidden for: anything the simulation can observe.
2. **Simulation vs presentation split**: `sim/` classes must not import or
   reference `Node`, `SceneTree`, or any engine singleton; they are pure
   `RefCounted`/`Object` data + logic. Presentation reads from the sim and
   never writes to it except through documented input entry points.
3. **Signals are events, not control flow inside a tick.** Emits happen at
   tick end (see rollback-fundamentals).
4. **Error handling**: fail loudly (`push_error` + error code return). No
   silent `if not x: return` swallows in session paths. Never `assert()` for
   runtime validation — asserts vanish in release templates.

Owned `RefCounted` callback graphs must not keep strong back-references. Use a
`WeakRef` when a game or test fixture refers back to its owning driver/session.
Engine resource-leak errors fail verification even if structured assertions pass.
Validate bounded view status separately from callback success and capture it before
expiration. A matching checksum cannot make a failed snapshot write successful.
Validate callback checksum width before encoding diagnostics; a typed `SaveResult`
does not constrain its contained byte array.
Check callback argument counts at configuration before replacing an active game.
Method existence alone does not prove a two-argument invocation is valid; accept
additional optional parameters. Reject incompatible reflected built-in parameter types,
but preserve valid Object/RefCounted/Variant views. Godot can erase script-specific
annotations; metadata cannot prove those types. Test actual dispatch as well as rejection.
Capture dynamic application callback returns as `Variant`, then validate the exact
contract before typed assignment or boolean use. An engine type error can bypass
guard release; coercion can accept malformed success values. Route rejected
returns through normal failure acknowledgement and test that guards release.

## File Hygiene

- Soft target: keep `.gd` files under 300 lines, same as the harness cap.
  Extract subsystems rather than growing a god class.
- No cyclic `preload`; dependencies flow one direction:
  `presentation -> session -> sim`.
- Improve names before adding comments. Keep only non-obvious reasons or
  constraints; retain required determinism explanations. Follow
  [user-copy](../user-copy/SKILL.md) for comments and public API docs.

## Formatting / Linting

```sh
gdformat .      # formatting
gdlint .        # style checks (once the codebase exists)
```

Related: [determinism](../determinism/SKILL.md),
[rollback-fundamentals](../rollback-fundamentals/SKILL.md).

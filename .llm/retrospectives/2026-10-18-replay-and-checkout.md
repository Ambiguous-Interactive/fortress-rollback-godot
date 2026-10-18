# Replay Validation and Clean Checkouts

## Evidence

- `test_replay_callbacks.gd` fails on main `ecf68a0`: an overflowing writer at
  frame zero or five still reaches `FRAME_EXHAUSTED`; the healthy callback passes.
  An uninitialized replay is also accepted as a complete empty recording.
- `replay_player.gd` expired the snapshot writer without reading its status.
  `snapshot_history.gd:finish_save` already checks that status separately from
  the callback result. Playback now follows the same validation boundary.
- Both replay suites pass on native Godot 4.3 and 4.7.2. The new suite joins
  the source-bound native/Chromium ownership corpus, including its existing
  unrelated-failure and aliasing negative controls.
- Hook-path table tests fail on the original literal-string comparison. An
  independent review then exposed a false pass for `symlink/../.githooks`:
  Bash logical traversal selected a different directory from Git. The added
  external-link control fails before `cd -P` and passes afterward.
- A clean candidate without generated UID/PNG metadata produces 110 new files
  during import. Retaining that metadata leaves zero new or modified files.
- Session-log cleanup is checked without local `progress/` files; root-local
  exemptions still reject escaped, near-prefix and wrong-depth targets.

## Findings and actions

| Finding | Durable action |
| --- | --- |
| Callback success and checksum equality can conceal a bounded writer failure. | Playback checks writer status before expiration and simulation. Integration docs describe `SNAPSHOT_FAILED`; callback regression tests cover first/later frames and persistent failure. |
| Equivalent-looking path strings can still identify different physical directories. | Hooks validation uses physical traversal; its table includes symlink plus parent components, valid paths, and missing/wrong paths. |
| A convincing red can fail at the wrong boundary. | Issue #118 moves accumulated guidance into focused references and adds a successful single-variable control before triple proof. |
| Historical notes exceeded the curation budget and local logs polluted shared history. | The foundations archive preserves immutable originals and canonical lessons; local progress stays ignored with bounded link exemptions. |

## Prune and limits

The foundations archive replaces repeated episodic notes rather than adding a
parallel source of rules. No pre-regression playback baseline exists for the
writer-status omission: it was present when playback was introduced. Healthy
callbacks and valid zero-frame recordings provide the independent controls.
This repair does not establish complete replay parity or close roadmap #45.
Final PR checks, feedback scans, merge identity and main CI belong in the local
session log and linked issue evidence.

Retro: findings-acted

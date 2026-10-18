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

## Online replay delivery

The online example now offers a separate, unchecked recording choice and a
36,000-frame cap. It downloads confirmed replay bytes in browsers and saves a
named native file. Terminal diagnostics and recovery messages remain intact.
Native success and file-open failure controls pass in isolated user directories on
both engine pins; recording consent and stalled-input controls also pass.

The exported download observer initially accepted an unrelated all-zero replay
because it checked only the replay's embedded histories. A fresh review also
found that a broad engine-version pattern accepted incorrect metadata. Both
mutations now fail: replay histories and stopped boundaries bind to the existing
room evidence, and metadata must match the verified native engine identity.
The saved binary artifact must equal the bytes fed back through production
`FortressReplay` and `FortressReplayPlayer` in the exported engine.

The first live download played correctly but failed independent input evidence:
Leave occurred after the sender's last physics step and before render capture.
Capturing input only while the transport was live omitted that final owned sample.
A deterministic shutdown-before-render test reproduces the missing sample.
The observer now captures retained actual input after shutdown too; terminal
snapshot publication remains separately fenced. This reinforces the existing
original-history and callback-boundary guidance rather than adding another rule.

The final layout keeps the replay controls on one row and scales the game area
to the remaining viewport; real screenshots verify both players remain visible.

## Prune and limits

The foundations archive replaces repeated episodic notes rather than adding a
parallel source of rules. No pre-regression playback baseline exists for the
writer-status omission: it was present when playback was introduced. Healthy
callbacks and valid zero-frame recordings provide the independent controls.
This repair does not establish complete replay parity or close roadmap #45.
Final PR checks, feedback scans, merge identity and main CI belong in the local
session log and linked issue evidence.

Retro: findings-acted

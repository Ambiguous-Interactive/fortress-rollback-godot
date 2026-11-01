# Retrospective: received files and source images

## Work under review

Session 138 extends the post-wrap donor-recovery comparison (#188), receives
actual browser replay files (#290), and binds native game execution to a
private authored-source image (#298). This is a tooling and qualification
change; it does not claim complete release or issue acceptance.

## Findings

| Finding | Evidence | Action |
| --- | --- | --- |
| An ending Git revision cannot identify a long native run's executed source. | `scripts/run_godot_tests.py` formerly read Git identity only after execution; new subprocess edit/commit controls qualify against the starting source image. | Execute the copied project and record every authored file's hash. Reject persistent source, image, commit and engine changes. |
| A successful export request does not prove a browser received the file or replaced playback. | The old Web prefix test replayed expected bytes; `browser/replay_download.cjs` now receives files and checks replacement, digest and frame count before playback. | Keep received-file and canonical playback gates separate. |
| A missed synthetic canvas click can look like a broken file picker. | An instant Open replay click missed the chooser. A bounded pointer press and trusted DOM control both opened the same importer with active browser activation. | Extend existing browser testing guidance with the paired control. |
| Wrapped trace labels do not prove physical history reuse. | The donor witness now exchanges 257 original frames through 128-row queues; short traces relabeled as wrapped fail their exact frontier checks. | Observe expired original history and retain raw absolute frames and independent canonical state. |
| Preflight failure can preserve stale success before execution starts. | Fresh review seeded `ownership.json`, refused host capacity and observed the earlier success unchanged. | Claim receipt ownership and invalidate it before waiting for host capacity; protect an active concurrent owner's receipt. |
| Tooling tests cannot compile a new exported GDScript fixture. | Godot 4.3 export rejected a nested digest index that shadowed a parameter after Python controls passed. | Rename the loop variable and compile the actual staged fixture on the minimum engine before final matrix qualification. |

## Actions taken

The native snapshot controls first failed without the receipt identity, then
passed for stable dirty work and isolated transient edits. Intervening edits,
commits and snapshot replacements reject qualification. Snapshot capture also
has regular-file, symlink and resource-bound controls.

Fresh native review found no implementation defect within the documented
scope. It retained explicit #298 gaps for imported Python bytecode, complete
descendant supervision and other result writers. Fresh drop-history review
found no findings and exercised the new paired traces and mutation controls.
Browser review's preflight finding received a regression, repair and clean
fresh review. A further review accepted direct decoded comparisons with the
retained full original, avoiding shared prefix-generation expectations.

The click lesson extends
[browser integration evidence](../skills/testing/references/browser-integration.md).
Existing source-freeze and received-file rules already cover the other lessons;
no additional overlapping skill was created. Final test and shipping evidence
belongs in the ignored session log and linked issue/PR state.

## Prune ledger

- Searched existing testing guidance before adding the click control.
- Retained the existing source-freeze, original-state and received-file rules.
- No reviewed source pin, historical discrepancy or broader release gate changed.
- Considered older retrospective consolidation; no duplicate canonical rule
  was introduced by this artifact.

## Outcome

Retro: findings-acted.
The broader acceptance of #188, #290 and #298 remains explicit in those issues.

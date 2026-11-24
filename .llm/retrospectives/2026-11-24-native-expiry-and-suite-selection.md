# Native expiry and test-selection evidence

| Finding | Evidence | Durable action |
| --- | --- | --- |
| Large reader digests turn unrelated edits into full-suite runs. | The #480 closeout and a repeat on main reported `unresolved_resource` for `lobby.gd` and selected all 142 unit suites. The already literal SDK path appeared in the dependency graph. The generated source assignment depended on the digest of the whole lobby. | Move the generated source and its digest to a fixed-input factory. [Test infrastructure](../skills/testing/references/infrastructure.md#faster-local-iteration) records how to verify the selection. |
| A Markdown data file can select just its actual consumers. | The unrelated-document fixture previously selected both suites. The replacement retains the reader on add, edit, delete and rename. A separate resource-loader fixture keeps the full fallback. A multiline heading fixture exposed a comment parser that could erase an actual call. | Keep exact raw file arguments separate from opaque resource formats. Check valid spelling variants and confirm the real checkout selects zero suites for an unrelated document. |
| A phase receipt can narrow a browser failure even when every final RPC stalls. | Hosted Firefox 4.3 hit each 1,024-packet hold cap before any page's local readiness. The final RPCs timed out. In the alternating 4.7.2 room, the native disconnect happened before warmup and had no remote identity in the baseline. | Preserve the first disconnect endpoint in the bounded warmup cutoff. [Browser integration](../skills/testing/references/browser-integration.md) records how to distinguish local observations from controller delivery. |

## Verification

`python3 scripts/tests/test_changed_suites.py` reported `Ran 7 tests … OK`. For
the documentation-only control, the local changed-suite runner reported
`selected_count: 0` from 142 suites. The CI plan verifier reported zero
partitions and cases with the expected `skipped` worker status. The baseline
runner selected 142 suites and ran 869 cases twice.

[Firefox relay:8](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/actions/runs/45475514809)
passed 40 frames on 4.7.2 and hit the hold cap on 4.3. The
[alternating room](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/actions/runs/45475520781)
passed 40 frames on 4.3 and failed during 4.7.2 warmup. The
[Chromium control](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/actions/runs/45475525407)
passed both engine pins. The browser qualification issues retain the remaining
reproduction and acceptance work.

State `findings-acted`.

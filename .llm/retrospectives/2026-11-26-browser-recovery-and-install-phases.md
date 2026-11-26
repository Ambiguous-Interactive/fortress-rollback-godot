# Browser recovery and install phases

| Finding | Evidence | Action |
| --- | --- | --- |
| WebKit may report send errors on both links during a planned overlapping close. | Godot 4.7.2 reached physical close and reported WebKit errors on pages 1 and 3. The close-proof regression failed with a deadline for both senders. The repaired test passes both independent reciprocal proofs and rejects swapped closers. | Derive the physical closers from the same pair list used by recovery. Require the missing-link control to prove every observed close before it publishes its diagnostic. |
| The expiry can arrive during a final status read or during a later trace read. | The entrypoint fixture first produced an empty selected scope. The second negative joined an expiry that arrived after collection started. | Select the directed links after bounded diagnostics. Use the same receipt cutoff for the join and retain later observations in the failure report. |
| An outer watchdog can discard the install journal before the installer reads it. | The two external SIGKILL controls originally retained just the journal path. Both now observe the last allowlisted phase in stderr. A fresh ARM64 cache installed both the historical and current OpenCode versions. | Flush each phase transition while the subprocess is running. Use the on-disk journal for finer detail when available. |
| The VS Code extension has its own width settings. | Both settings defaulted to null. The bundled formatter inherited 180 in the repository root and reported 100 without project configuration. Passing the configured 180 preserved the 139-character fixture outside the project. | Set the extension's formatter and linter widths. Check every source width configuration in the harness suite. |

The [transport note](../knowledge/transport-tooling.md) replaces the earlier
missing-link checklist with the full close-proof requirement. The
[installer note](../knowledge/devcontainer-tooling.md) records the evidence
that survives a discarded layer.

State `findings-acted`.

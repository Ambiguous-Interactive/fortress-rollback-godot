# Reviewed pin advancement

| Finding | Evidence | Action |
| --- | --- | --- |
| The advancement command treated unresolved paths as a notice. | The regression expected exit one and received zero. A single unreviewed Rust change rewrote the fixture pin. | Require exact path decisions and bind them to both revisions and archive digests. |
| An archive path can point to different bytes after the digest is read. | Fresh review replaced the candidate after hashing and before extraction. The regression failed at the candidate tree comparison. | Copy both archives to a private directory. Verify, hash, and extract those copies. |
| An explicitly supplied JSON null previously passed when the flagged set was empty. | Fresh review reproduced exit zero for comment-only drift with a null decision file. | Require the object shape for every supplied file. Use an empty bound decision set when the option is omitted. |
| A manifest digest alone does not prove a report covers upstream drift. | The CI fixture removed the real flagged path and recomputed its manifest digest. The verifier reclassified the archives and rejected the omitted decision. | Rebuild the expected report in Gate and compare it with the tracked report. |

The focused drift suite ran 33 tests and returned `OK`. The real Fortress
candidate comparison from `d124c890` to `fc0ed301` flagged 320 paths.
The advancement attempt returned an unresolved-path error and preserved
the scratch manifest byte for byte.

The [operator guide](../../docs/reference/README.md#observation-and-advancement)
now describes the decision file and Gate check. It replaces the earlier
wording that treated path review as a step after pin advancement.

State `findings-acted`.

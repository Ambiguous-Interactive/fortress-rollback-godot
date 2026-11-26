# Relay receive boundaries

| Finding | Evidence | Action |
| --- | --- | --- |
| An addressed carrier can reach a browser event before the relay decoder runs. | The Firefox TLS control held the original event in the witness listener. The controller observed `relay_decode` and matched the carrier SHA-256 at both proxy boundaries and the browser. | Record the original message at listener entry. Count its replay once. |
| Data can enter the proxy while an earlier TLS write is pending. | A chunk queued behind a held write lacked an inlet mark in the first implementation. The control now records both inlets before either outlet. | Observe data before the forwarding queue. Record the outlet from write completion. |
| Different snapshots can create an apparent gap. | The join controls exercise evicted proxy records, missing pages, a TLS write after the page read began, evicted raw records and different copies of a single stamp. | Publish coverage gaps and join the exact carrier digest. |

The [transport note](../knowledge/transport-tooling.md) records the evidence
needed to interpret a missing stage. The
[migration guide](../../docs/native-backend-migration.md) replaces the single
focused-history limit with limits for the individual archives.

State `findings-acted`.

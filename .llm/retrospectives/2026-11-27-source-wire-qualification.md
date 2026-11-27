# Source wire qualification

| Finding | Evidence | Action |
| --- | --- | --- |
| Stable packet semantics can conceal a raw wire change. | The 38 P2P schedules retained ordered records and packet semantics. All 9,896 headers switched from version 2 to 6, and 24 checksum reports gained a basis token. | Select the raw contract by source SHA before projecting a packet. |
| JSON decoding can hide a malformed checksum report. | Inserting a second `basis_token` into the candidate `checksums_match` trace previously returned `{"complete": true, "records": 102, "packets": 72}`. The same input now exits 2 with `p2p validation: duplicate trace field: basis_token`. | Reject duplicate members before validating recorder output. |
| The fixed-membership corpus exercises only the zero basis. | Actual single-target and grouped drop runs emitted tokens `4176669562639073937` and `5610829596750384181`, with 20 and 14 nonzero survivor reports. Independent freeze-term and canonical-row reconstruction matched each run. | Validate the token at its full width and use coordinated-drop evidence for nonzero values. |

The candidate source was `25e8020d1a5fd40c4f16b37f97b5ec5329a8566d`. Godot 4.3
and 4.7.2 each ran the 38 saved P2P schedules and 26 handshake schedules twice.
Both engines matched the candidate's projected evidence. The summary SHA-256
digests were `10c184a2e1f308835c6f8c217667e559ee5c705c7d6d751a55b947d3ce82e803`
for P2P and `634dfb59022969d5359720ee4108bae8a625963ce31125b543879e00ecf45a80`
for handshake.

The [P2P operator guide](../../docs/oracle-p2p.md#raw-source-revision) records
the exact source selection, raw checksum contract, and coordinated-drop
boundary. The historical launcher commands still select the reviewed source.
The broader upgrade and its remaining qualification live in
[#546](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/546).

State `findings-acted`.

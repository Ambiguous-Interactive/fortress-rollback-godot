# Live commit acknowledgement loss

The deterministic comparison already covered lost follower confirmation.
The previous exported-browser cell withheld only COMMIT. Revalidating the
Godot 4.7.2 Chromium receipt from session 221 with the paired validator
failed with `peer-drop lost-commit acknowledgement retry evidence missing`.

Both directions use the same capture and packet validation. In the first
Godot 4.3 Chromium run, the follower withheld a 109-byte REPORT/COMMITTED
and sent a byte-identical retry 49,060 microseconds later. The coordinator
also retried COMMIT, recorded the follower acknowledgement, and both
survivors compared 38 canonical prefixes. The poll clock can measure less
than the publication retry interval because the first packet is recorded
at withholding time. The validator keeps the positive-delay check.

The fresh review identified two ordering dependencies. The gameplay
confirmation wait does not establish that the control exchange finished, and
moving the row fields past the early second-departure return changed that
cell's receipt. The witness now waits for sent retry evidence on the follower
and receipt on the coordinator before building the row in its original
location. A table-driven control changes only the follower retry's connection
identifier to prove that byte equality is required even for valid packets.

The [transport note](../knowledge/transport-tooling.md) replaces the old
single-direction procedure with the paired protocol. The earlier retrospective
remains historical evidence for the original cell.

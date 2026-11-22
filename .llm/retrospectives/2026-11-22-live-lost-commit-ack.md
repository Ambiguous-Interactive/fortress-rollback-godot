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

## Merge-group findings

The first group exposed a duplicate acknowledgement already queued when the
first acknowledgement was withheld. The grouped 4.3 direct receipt reported
three sends and a first retry delay of zero despite matching bytes. The
transport now withholds all exact copies addressed to the same peer at that
clock sample, accounts for them separately, and keeps the positive-delay
requirement. The native clock control exercises the old failure, a different
address that resolves to the same slot, and a changed payload.

The grouped 4.7.2 spectator delayed-accept cell completed playback and
reported `net::ERR_ABORTED` for the admission fetch. A split 11-byte
`Cache-Control: no-store` response on the pinned Chromium 156.0.8078.4
reproduced the failure after the streamed reader returned valid JSON.
`Response.json()` returned the same JSON with a finished request.
The pinned Godot Web adapter uses a streaming reader, which matches the
[Playwright report](https://github.com/microsoft/playwright/issues/42742).
The exported spectator fixture now uses full JSON consumption for its
loopback control requests. It retains the browser's three-second abort
signal, actual held HTTP acceptance, and fatal observer for network errors.
The [transport note](../knowledge/transport-tooling.md) records both lessons.

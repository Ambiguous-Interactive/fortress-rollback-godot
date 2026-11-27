# Relay generation publication on Firefox 4.3

Both sessions used eight peers, the pinned Firefox and Godot builds, and
Linux ARM64 CPUs 0–2. Each completed 40 canonical input and state rows and
eight intentional Leaves. The original read timed out after observing
generation 2. The recovery read retained generation 3. The optimized
session selected its generation 3 inside the original deadline.

| Capture | Server encode and flush | Evidence |
| --- | --- | --- |
| Original | 4,895.298 ms | [generation 3](before-relay-8-server-trace.json.gz), [server log](before-relay-8-server.log), [controller timing](before-controller-timing.json) |
| Optimized | 2,005.100 ms | [generation 3](after-relay-8-server-trace.json.gz), [server log](after-relay-8-server.log), [controller timing](after-controller-timing.json) |

The server records are original files compressed with `gzip -n`. Match their
uncompressed SHA-256 values to [provenance.json](provenance.json). The controller
files extract the timing and counts from the original browser receipts. The
shared clock domains and the request generation let the reader compare each
run's own server and controller intervals.

```sh
gzip -cd before-relay-8-server-trace.json.gz | sha256sum
gzip -cd after-relay-8-server-trace.json.gz | sha256sum
```

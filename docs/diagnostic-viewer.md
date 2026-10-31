# Inspect a diagnostic capture

In the online example, choose **Inspect diagnostic file**, then **Open diagnostic**.
Select a downloaded diagnostic `.json` file. Native builds open a file dialog;
browser builds use the browser's file picker. Inspection runs locally and needs
no server, SDK, room, or network connection.

Enable **Include game state and inputs in diagnostics** before Ready when making
the capture. A report without canonical state and inputs cannot be reproduced.
Keep the original report when comparing builds and review its state, input, and
application metadata before sharing it.

The viewer accepts a complete online example report or its `trace` object, up to
1 MiB. It requires `fortress-online-integer-v1`, a contiguous retained window, an
initial saved state, and a later saved boundary. Imports with invalid JSON, a
future trace schema, another game version, or incomplete canonical evidence show
an error and preserve the previously loaded window and playback position.

Use **Step** to restore the first captured boundary and consume one retained row.
Each row checks its available canonical state and checksum before applying its
recorded inputs. **Play** consumes at most one row per presentation tick;
**Step** pauses playback, and **Restart** resets playback to the beginning of the
retained window. Completion or failure stops playback. No network input is sampled.
The capture's descriptive `replay_command` is never executed.

Restarting or successfully importing another file retires the previous playback.
Retained old player handles cannot execute more callbacks. Viewer controls leave playback unchanged
while a game callback owns it; they become available again when that callback returns.

The status shows the application version, captured seed text, first and last
retained boundaries, next row, successful canonical comparisons, and successful
advances. Seed text stays text, including values larger than a signed 64-bit
integer. The simulation restores the captured RNG state rather than starting
again from that seed. Before the first Step, the game display shows its default
state; it becomes the restored captured execution when playback begins.

The session's reported callback failure, the capture's reported divergence and
the viewer's playback comparison failure are shown separately. New diagnostic
reports name `save_state`, `load_state` or `simulate_frame` and the failed request
frame. Historical reports without callback metadata remain readable. A state
failure reports the first compared frame and differing byte offset; checksum failures show expected and actual values. Callback or
snapshot failures are separate errors. A failing row's inputs are not applied.
State at boundary F precedes input F.

A matching window establishes only that this build reproduced the retained local
execution. It does not prove remote agreement, original seed correctness, or the
first divergence before the retained window. A final successful ADVANCE without
a following SAVE is applied but cannot be checked; the comparison and advance
counts distinguish these operations. A final SAVE without input is compared
without inventing an advance.

For headless reproduction and application callback integration, see
[Reproduce a captured canonical window](diagnostic-reproduction.md).

# P2P supported network profiles

This page publishes the supported network profiles of the initial P2P scope and
the reproducible report behind them: which simulated network shapes the
differential oracle actually compares, which profiles are explicitly excluded,
which differences are explained, and the single command that re-executes every
committed case and fails closed on any unexplained divergence. It is the P5
completion evidence for
[#34](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/34);
per-case observation limits live in the [P2P oracle guide](../oracle-p2p.md) and
the [handshake oracle guide](../oracle-handshake.md). Advanced-parity areas
(replay, spectators, coordinated drop, live transports) carry their own gates
and are declared out of this scope, not silently missing.

"Supported" here means: the profile is a committed case in a differential
launcher, executed against the pinned upstream revision on both pinned engines
(Godot 4.3 and 4.7.2), twice per side in fresh processes, with exact ordered
requests, callbacks, packets and canonical state bytes compared and every
process negative control failing at its declared diagnostic. Any disagreement
fails the gate — the launcher shrinks the failing schedule to its first
divergence and refuses — so a green wave is a zero-unexplained-divergence
receipt by construction.

## Reproduce

One command re-executes the whole wave in bounded-parallel subprocesses with
fail-closed aggregation (each launcher keeps its own interpreter, output
directory and receipt; the shared cargo target stays correct under cargo's
build lock):

```sh
python3 scripts/oracle/parallel_launchers.py --godot godot --suffix <engine-version> --skip-formal
```

Single families run directly: `make p2p-probes` (gameplay, lifecycle, layouts,
widths, capacity), `make handshake-probes` (handshake), and
`python3 scripts/oracle/p2p_wrap_launch.py --godot godot` for the committed
ring-wrap fixtures. The oracle tooling negative controls run with
`make test-oracle`. Receipts land under `.cache/reference/results/` in a
per-launcher `<launcher>-<suffix>` directory (machine-local); the public
evidence is the merge-triggered Reference Baseline
workflow, whose `oracles` leg executes the same command for both pins — for
example the qualification run of PR
[#392](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/pull/392)
([Reference Baseline](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/actions/runs/44165871602),
33/33 jobs successful) and the main-branch Gate runs that followed it.

## Compared matrix

| Axis | Compared values | Owning cases |
| --- | --- | --- |
| Roster size | every supported count 2–8, each at input delay 0 and 2 | `mesh_<n>_delay_<d>` |
| Packet faults | loss, reorder/duplicate, prediction stall/recovery, retry timing at exact interval boundaries | `mesh_<2,4,8>_<loss,reorder,stall,retry>` |
| Prediction window | default 4; deepest compared window 8, including the stall schedule window 4 refuses and window 8 recovers | `mesh_<n>_window_8`, `mesh_2_window_8_stall` |
| Construction delay profiles | heterogeneous per-peer schedules `[2,0]`, `[2,1,0]` (under loss), `[2,0,2,0]`, couch `[2,2]`, plus the profile-plus-raise differential and its pinned minimized regression | `mesh_*_delays_*`, `mesh_2_delays_2_0_raise[_min]` |
| Runtime delay changes | raise, repeat, refused decrease and too-large values under loss, rapid churn and stall, compared after each peer's first step | `mesh_*_delay_change_*` |
| Endpoint layouts | solo machines; couch `[2,2]` and `[3,1]`; three-machine split `[2,1,1]` and `[2,2,2]`; couch loss and reversed-withheld stall recovery | `mesh_*_couch_*`, `mesh_*_split_*` |
| Input width | default 4-byte rows; minimum width 1 (including a loss fault under it); wide 32-byte rows; the combined maximum profile (width 32, window 8, eight peers) | `mesh_*_width_*` |
| Ring wrap | total-silence flood wrapping the default 128-row ring at every count 2–8; capacity 9 (flood and partial outage); 32-row fanout at eight peers; window 8; width 1 and 32; couch/split layouts; delay profiles | `mesh_*_wrap_flood*`, `mesh_3_capacity9_late_flight` |
| Asymmetric recovery | asymmetric correction histories across queue wrap with unequal frontiers | `mesh_3_asymmetric_recovery_wrap` |
| Lifecycle | pacing/skew, quality echo and RTT, frame advantage, interruption/resume, disconnect boundary, one-way partition, heal, three-player and eight-player mesh heal, fairness rotation, checksum match/repair/diverge | `control_boundaries` … `pacing_skew` |
| Handshake | full negotiated-field matrix both directions (min compat, roster, width, fps, prediction, desync interval, feature bits, config digest), precedence, retries, timeout recovery, duplicate/reordered echoes, wrong source/connection | the 26 `handshake` scenarios |

The generated inventory block at the end of this page lists every case name by
launcher. It is produced by `scripts/oracle/profile_report.py` from the same
case tables the launchers execute, and `--check` fails when the committed block
drifts from those tables, so the published inventory cannot outlive the
evidence it names.

## Declared exclusions

These profiles are outside the supported P2P scope. They are explicit release
exclusions, not silent gaps:

- Meshes of three or more distinct endpoint identities at prediction window
  zero (any delay) and at prediction window one with delay zero: pinned
  upstream source-only audits reproduce healthy gossip deadlock there. Two
  identities at windows zero/one and three or more identities at window one
  with delay two remain accepted.
- Rust/Godot mixed wire sessions: outside the committed compatibility scope.
- Real transports and browsers — SignalFish relay, WebRTC, exported witnesses
  and live recovery: owned by the S3–S5 tasks and
  [#75](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/75),
  not by this simulated scope.
- Input widths beyond the compared representative set. The product admits rows
  up to 65536 bytes; the differential grammar compares the default 4-byte row,
  the minimum width 1 and the 32-byte wide row. Wider rows are covered by the
  width-encoding unit contracts, not by differential fixtures.
- Prediction windows beyond the compared representative set. The product
  admits windows up to 128; the committed fixtures pin the family default 4
  and the boundary window 8 (the lifecycle corpus also runs at 8). The
  comparison tools accept windows 2 through 8 and default-reject 0 and 1 —
  the gate checks that rejection and audits the low-window behavior
  source-only — but no committed differential fixture pins windows 2, 3 or
  above 8; those are covered by the schema and validation contracts, not by
  differential fixtures.
- Advanced parity — deterministic replay, spectators, coordinated drop and
  history transfer, hot join and redundant hosts: gated by
  [#45](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/45),
  [#47](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/47) and
  [#48](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/48).
- Godot lockstep checksum SAVE capture: a product extension the pinned source
  never emits; it is validated independently rather than claimed as source
  parity.

## Explained divergences

Every divergence below is a documented projection decision, reviewed and
recorded; none is unexplained:

- Upstream's first advance emits two identical initial saves at frame zero;
  comparison removes exactly one adjacent identical pair. All later saves stay
  ordered and compared.
- Upstream reports a stalled step as successful with an unchanged frame while
  the Godot driver reports `PREDICTION_STALL`; only the source observation maps
  the successful unchanged step to that error.
- Godot's `inputs_received` extension events have no upstream counterpart;
  they are validated in a separate strict inventory and never counted as
  upstream event parity.
- Terminal policy: the Godot fixed-membership session halts while upstream
  continues. Only the final first actual terminal trigger receives the
  documented projection, with exact pre-operation state and owned notification
  suffix; the raw source continuation stays retained.
- Speculative recording checksums carry the pinned upstream discrepancy
  [#253](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/253);
  they are never normalized into canonical evidence. This belongs to the
  replay-recording comparison, which is outside the P2P wave above.
- Runtime delay raises stamp Godot's send with the peer's last step or poll
  time, so retries and keepalives may fire one tick earlier than upstream.
  This is an accepted timing difference, not a semantic one.
- Before a peer's first input, upstream accepts any fitting delay while
  Godot's agreed configuration owns the starting delay and refuses the change
  with `UNSUPPORTED`; a documented divergence, not compared.

## Zero unexplained divergences

The committed corpora above are the whole initial P2P scope, and the wave is
fail-closed: exact comparisons on both pins, twice per side in fresh
processes, raw compression validation, per-case evidence, full negative
control sets, and first-divergence shrinking on any disagreement. A launcher
exit of zero is the report; the inventory block is its case list; the latest
public execution is the Reference Baseline run cited above, and every future
merge re-qualifies the same command through the merge queue. Tooling drift is
controlled the same way: `make test-oracle` proves the process controls still
reject corrupted, truncated, reordered or stale evidence, and
`python3 scripts/oracle/profile_report.py --check docs/reference/p2p-profiles.md`
proves the inventory block still names exactly the committed corpora.

<!-- inventory: generated by scripts/oracle/profile_report.py; edit only through the case tables it derives from -->

Committed inventory: 105 cases across 3 launchers, derived from the case tables the launchers execute at the pinned revision.

- `handshake` — 26 cases:
  `model_matching`, `duplicate`, `reordered`, `timeout_retry`, `request_then_reply`
  `unknown_echo`, `wrong_source`, `wrong_connection`, `reply_refreshes_retry`
  `request_min_compat_version`, `request_num_players`, `request_input_bytes_per_player`
  `request_fps`, `request_max_prediction`, `request_desync_interval`, `request_features`
  `request_config_digest`, `reply_min_compat_version`, `reply_num_players`
  `reply_input_bytes_per_player`, `reply_fps`, `reply_max_prediction`, `reply_desync_interval`
  `reply_features`, `reply_config_digest`, `precedence`

- `p2p` — 62 cases:
  `mesh_2_delay_0`, `mesh_2_delay_2`, `mesh_3_delay_0`, `mesh_3_delay_2`, `mesh_4_delay_0`
  `mesh_4_delay_2`, `mesh_5_delay_0`, `mesh_5_delay_2`, `mesh_6_delay_0`, `mesh_6_delay_2`
  `mesh_7_delay_0`, `mesh_7_delay_2`, `mesh_8_delay_0`, `mesh_8_delay_2`, `mesh_2_loss`
  `mesh_2_reorder`, `mesh_2_stall`, `mesh_2_retry`, `mesh_4_loss`, `mesh_4_reorder`
  `mesh_4_stall`, `mesh_4_retry`, `mesh_8_loss`, `mesh_8_reorder`, `mesh_8_stall`, `mesh_8_retry`
  `mesh_2_window_8`, `mesh_4_window_8`, `mesh_8_window_8`, `mesh_2_window_8_stall`
  `mesh_4_couch_2x2`, `mesh_6_split_2x2x2`, `mesh_4_couch_loss`, `mesh_4_couch_stall`
  `mesh_2_delays_2_0`, `mesh_3_delays_2_1_0_loss`, `mesh_4_delays_2_0_2_0`
  `mesh_4_couch_delays_2_0`, `mesh_2_delays_2_0_raise`, `mesh_2_delays_2_0_raise_min`
  `mesh_2_width_1`, `mesh_4_width_1_loss`, `mesh_4_width_32`, `mesh_8_width_32_window_8`
  `mesh_2_delay_change_loss`, `mesh_4_delay_change_rapid`, `mesh_3_delay_change_stall`
  `mesh_3_asymmetric_recovery_wrap`, `mesh_3_capacity9_late_flight`, `control_boundaries`
  `quality_echo_resume`, `quality_rtt_advantage`, `disconnect_boundary`, `partition_one_way`
  `partition_heal`, `partition_heal_mesh`, `partition_heal_mesh8`, `partition_fairness`
  `checksums_match`, `checksums_repair`, `checksums_diverge`, `pacing_skew`

- `p2p-wrap` — 17 cases:
  `mesh_2_wrap_flood`, `mesh_3_wrap_flood`, `mesh_4_wrap_flood`, `mesh_5_wrap_flood`
  `mesh_6_wrap_flood`, `mesh_7_wrap_flood`, `mesh_8_wrap_flood`, `mesh_8_wrap_flood_32`
  `mesh_4_wrap_flood_window_8`, `mesh_3_wrap_flood_delays_2_1_0`, `mesh_4_wrap_flood_delays_2_0`
  `mesh_4_wrap_flood_capacity_9`, `mesh_4_wrap_flood_couch_2x2`, `mesh_4_wrap_flood_split_2x1x1`
  `mesh_4_wrap_flood_couch_3x1`, `mesh_4_wrap_flood_width_32`, `mesh_4_wrap_flood_width_1`

<!-- end inventory -->

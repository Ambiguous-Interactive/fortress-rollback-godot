"""Five minimum-pin Chromium parts, using native and browser observations from hosted run 45090341692."""
from pathlib import Path

# Negative native, negative browser, positive native, positive browser, in seconds.
# Browser pages contain four suites. Allocate time after the two-second page startup in proportion to measured native work.
# Suites under four seconds in both measurements use the same estimate as newly registered suites.
COSTS = {
    "diagnostic_viewer": (5, 3, 2, 2),
    "driver_drop_parity": (7, 5, 8, 6),
    "driver_peer_parity": (44, 30, 44, 29),
    "integration_demo": (5, 4, 2, 2),
    "peer_drop_backfill": (30, 19, 17, 11),
    "peer_drop_capacity": (24, 15, 22, 14),
    "peer_drop_commit": (63, 51, 39, 27),
    "peer_drop_donor_fairness": (23, 19, 24, 16),
    "peer_drop_eviction": (11, 6, 11, 7),
    "peer_drop_history": (19, 11, 20, 13),
    "peer_drop_history_pressure": (6, 4, 2, 2),
    "peer_drop_inventory": (23, 13, 12, 8),
    "peer_drop_late_ack": (33, 21, 33, 21),
    "peer_drop_multi_slot": (23, 15, 23, 15),
    "peer_drop_overlap": (21, 14, 20, 13),
    "peer_drop_plan_fairness": (9, 6, 11, 7),
    "peer_drop_ready_pressure": (5, 4, 5, 3),
    "peer_drop_remote_donor_pressure": (5, 3, 4, 3),
    "peer_drop_replay": (12, 8, 7, 5),
    "peer_example_ownership": (49, 35, 52, 37),
    "peer_lifecycle": (7, 5, 4, 3),
    "peer_recovery": (5, 3, 6, 4),
    "peer_scene_controls": (21, 14, 10, 7),
    "peer_session": (11, 7, 6, 4),
    "replay_input_navigation": (7, 5, 7, 5),
    "replay_speed": (7, 5, 6, 5),
    "replay_viewer": (10, 8, 9, 8),
    "signalfish_spectator_host": (6, 4, 2, 2),
    "spectator_demo": (20, 12, 17, 13),
    "spectator_model": (4, 3, 2, 2),
    "spectator_replay_viewer": (58, 47, 66, 52),
    "spectator_session": (2, 5, 2, 2),
    "spectator_status": (1, 5, 2, 5),
    "stalled_gossip": (13, 11, 7, 6),
}


def minimum_chromium_cost(suite, phase):
    if phase not in ("negative", "positive"):
        raise ValueError("minimum Chromium parts require one phase")
    row = COSTS.get(Path(suite).stem.removeprefix("test_"), (2, 2, 2, 2))
    return row[:2] if phase == "negative" else row[2:]


def minimum_chromium_parts(suites, phase, download_suite):
    costs = {suite: minimum_chromium_cost(suite, phase) for suite in suites}

    def seconds(group):
        native = [costs[suite][0] for suite in group]
        # Four native workers run together before serial browser pages. The alias control occupies one page slot.
        pages = (len(group) + 4) // 4
        downloads = 125 if phase == "positive" and download_suite in group else 0
        return max(max(native), sum(native) / 4) + sum(costs[s][1] for s in group) + pages * 2 + downloads

    groups = [[] for _ in range(5)]
    for suite in sorted(suites, key=lambda s: (-seconds([s]), s)):
        group = min(groups, key=lambda current: seconds([*current, suite]))
        group.append(suite)
    return groups

"""Balance minimum-pin ownership using observed runs 45090341692 and 45095685122."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import threading

# Each pair is median native and estimated Web seconds across both runs and phases.
# Allocate each four-suite browser page by its native timings after a two-second page startup.
COSTS = {
    "diagnostic_viewer": (4, 3),
    "driver_drop_parity": (8, 6),
    "driver_peer_parity": (42, 29),
    "example_scene_exit": (4, 3),
    "integration_demo": (5, 4),
    "peer_drop_backfill": (31, 20),
    "peer_drop_capacity": (23, 15),
    "peer_drop_commit": (60, 50),
    "peer_drop_donor_fairness": (23, 16),
    "peer_drop_eviction": (11, 7),
    "peer_drop_history": (19, 12),
    "peer_drop_history_pressure": (6, 4),
    "peer_drop_inventory": (22, 14),
    "peer_drop_late_ack": (33, 21),
    "peer_drop_multi_slot": (23, 15),
    "peer_drop_overlap": (20, 14),
    "peer_drop_plan_fairness": (10, 7),
    "peer_drop_ready_pressure": (5, 4),
    "peer_drop_remote_donor_pressure": (5, 3),
    "peer_drop_replay": (12, 9),
    "peer_example_ownership": (48, 35),
    "peer_lifecycle": (7, 4),
    "peer_recovery": (6, 4),
    "peer_scene_controls": (18, 12),
    "peer_session": (10, 6),
    "replay_input_navigation": (7, 5),
    "replay_speed": (6, 5),
    "replay_viewer": (11, 8),
    "replay_viewer_lifetime": (4, 3),
    "signalfish_spectator_host": (5, 3),
    "signalfish_spectator_relay": (4, 2),
    "spectator_demo": (18, 13),
    "spectator_model": (4, 3),
    "spectator_replay_viewer": (57, 50),
    "spectator_session": (2, 4),
    "stalled_gossip": (12, 10),
}


def minimum_chromium_cost(suite):
    return COSTS.get(Path(suite).stem.removeprefix("test_"), (2, 2))


def balanced_lanes(weights, workers):
    lanes = [[] for _ in range(workers)]
    totals = [0.0] * workers
    for index in sorted(range(len(weights)), key=lambda i: -weights[i]):
        lane = totals.index(min(totals))
        lanes[lane].append(index)
        totals[lane] += weights[index]
    return lanes, max(totals)


def minimum_chromium_parts(suites, phase, download_suite, alias_suite):
    if phase not in ("negative", "positive"):
        raise ValueError("minimum Chromium parts require one phase")
    costs = {suite: minimum_chromium_cost(suite) for suite in [alias_suite, *suites]}

    def seconds(group):
        ordered = sorted([alias_suite, *group])
        native = [costs[s][0] for s in ordered]
        pages = [2 + sum(costs[s][1] for s in ordered[offset:offset + 4]) for offset in range(0, len(ordered), 4)]
        downloads = 125 if phase == "positive" and download_suite in group else 0
        return balanced_lanes(native, 4)[1] + balanced_lanes(pages, 2)[1] + downloads

    groups = [[] for _ in range(5)]
    for suite in sorted(suites, key=lambda s: (-seconds([s]), s)):
        group = min(groups, key=lambda current: seconds([*current, suite]))
        group.append(suite)
    return groups


def chromium_page_wave(page_suites, native_seconds, execute, workers):
    """Run two independent Chromium processes on four cores. Return results in declaration order."""
    if workers == 1:
        return [execute(index) for index in range(len(page_suites))]
    costs = [sum(native_seconds[suite] for suite in page) for page in page_suites]
    lanes, _ = balanced_lanes(costs, workers)
    stopped = threading.Event()
    results = [None] * len(costs)

    def run_lane(indices):
        try:
            for index in indices:
                if stopped.is_set():
                    break
                results[index] = execute(index)
        except BaseException:
            stopped.set()
            raise

    with ThreadPoolExecutor(max_workers=workers) as pool:
        try:
            list(pool.map(run_lane, lanes))
        finally:
            stopped.set()  # An interrupted caller joins only the already active pages.
    return results

"""Bound each browser label by its actual room count and bootstrap allowance."""
from concurrent.futures import ThreadPoolExecutor
import sys

import owned_process
from run import capture

# Live-page peaks per label: the largest room a label runs. A three-room label
# runs 2/4/8-player rooms serially inside its own browser process, so its peak
# is one eight-player room; single-room labels peak at their only room size.
PEAK_PLAYERS = {'clean': 8, 'faults': 8, 'mixed': 8, 'mixed-default': 8, 'mixed-close': 8,
                'corrupt': 2, 'default': 2, 'mixed-disabled': 2, 'recording-pressure': 2,
                'peer-drop': 3, 'peer-drop-corrupt': 3, 'peer-drop-close': 3,
                'peer-drop-answer': 3, 'peer-drop-relay': 3, 'peer-drop-missing': 3, 'peer-drop-missing-lost': 3, 'peer-drop-donor-process': 3,
                'peer-drop-commit': 3,
                'peer-drop-second': 3, 'peer-drop-second-after-ack': 3, 'peer-drop-second-last-turn': 3, 'peer-drop-overlap': 4,
                'peer-drop-rollback': 3, 'peer-drop-foreign': 3, 'peer-drop-room': 3, 'peer-drop-room-continue': 3,
                'peer-drop-process': 3, 'peer-drop-process-missing': 3, 'peer-drop-room-after-drop': 3,
                'peer-drop-room-before-drop': 3}
ROOM_COUNTS = {'clean': 3, 'faults': 3, 'mixed': 3, 'mixed-default': 3, 'mixed-close': 3,
               'corrupt': 1, 'default': 1, 'mixed-disabled': 1, 'recording-pressure': 1,
               'peer-drop': 1, 'peer-drop-corrupt': 1, 'peer-drop-close': 1,
               'peer-drop-answer': 1, 'peer-drop-relay': 1, 'peer-drop-missing': 1, 'peer-drop-missing-lost': 1, 'peer-drop-donor-process': 1,
               'peer-drop-commit': 1,
               'peer-drop-second': 1, 'peer-drop-second-after-ack': 1, 'peer-drop-second-last-turn': 1, 'peer-drop-overlap': 1,
               'peer-drop-rollback': 1, 'peer-drop-foreign': 1, 'peer-drop-room': 1, 'peer-drop-room-continue': 1,
               'peer-drop-process': 1, 'peer-drop-process-missing': 1, 'peer-drop-room-after-drop': 1,
               'peer-drop-room-before-drop': 1}
# Overlapping labels never hold more live pages than one eight-player room, the
# busiest shape a hosted runner already proves (#104's runner-contention budget).
MAX_CONCURRENT_PLAYERS = 8


def room_count(label):
    if label not in ROOM_COUNTS:
        raise ValueError(f'unknown browser witness label: {label}')
    return ROOM_COUNTS[label]


def label_waves(labels, overlap):
    """Plan waves of concurrently runnable labels in the caller's order.

    Every wave holds live pages within MAX_CONCURRENT_PLAYERS. Without overlap
    every label gets its own wave, which reproduces the historical serial run.
    The tables above restate the room ternary in webrtc.cjs and are pinned to
    its literal source by the probe suite, so the two cannot drift apart.
    """
    waves = []
    for label in labels:
        room_count(label)
        peak = PEAK_PLAYERS[label]
        if not overlap:
            waves.append([label])
            continue
        for wave in waves:
            if peak + sum(PEAK_PLAYERS[member] for member in wave) <= MAX_CONCURRENT_PLAYERS:
                wave.append(label)
                break
        else:
            waves.append([label])
    return waves


def run_wave(labels, overlap, operation):
    """Run label waves concurrently, joining every member before naming failures.

    Single-label waves call the operation inline with no handle, so a serial
    plan keeps the historical raw-exception behavior exactly: an interrupt
    there lands inside the owning call's own cleanup. Packed waves give each
    member a cancellation handle and join all members first; an interrupt in
    the joining caller cancels every active tree before joining the workers
    (#397), so the join waits for cleanup instead of for each member's own
    deadline, while ordinary per-label failures keep the join-all naming in
    the caller's label order. Returns one result per label under its name.
    """
    results = {}
    for wave in label_waves(labels, overlap):
        if len(wave) == 1:
            results[wave[0]] = operation(wave[0], None)
            continue
        handles = {label: owned_process.CancelHandle() for label in wave}
        failures = {}
        with ThreadPoolExecutor(max_workers=len(wave)) as pool:
            try:
                waits = [pool.submit(_guarded, operation, label, handles[label], results, failures)
                         for label in wave]
                for wait in waits:
                    wait.result()
            except BaseException:
                # Cancel first: every active tree terminates now, so the join
                # below waits for the workers' cleanup, never for a deadline.
                # Submission sits inside this handler too, so an interrupt
                # that lands mid-submission still cancels every handle — one
                # whose member never started is cancelled before it can, and
                # each attempt is isolated against failures (a second
                # interrupt arriving inside one cancel is die-now by
                # convention and is not isolated), so a failed cancellation
                # neither skips the remaining handles nor replaces the
                # interrupt.
                broken = []
                for label in wave:
                    try:
                        handles[label].cancel()
                    except Exception as cancel_failure:
                        broken.append(f'{label}: {type(cancel_failure).__name__}: {cancel_failure}')
                if broken:
                    print('browser witness wave: cancel failures — ' + '; '.join(broken),
                          file=sys.stderr, flush=True)
                raise
        if failures:
            named = '; '.join(f'{label}: {type(failures[label]).__name__}: {failures[label]}'
                              for label in labels if label in failures)
            raise ValueError(f'browser witness label failed: {named}')
    return results


def _guarded(operation, label, cancel, results, failures):
    try:
        results[label] = operation(label, cancel)
    except Exception as error:
        failures[label] = error


def run_browser(command, environment, log, rooms, cancel=None):
    if type(rooms) is not int or rooms not in (1, 3, 4, 5):
        raise ValueError("browser room count must be one, three, four or five")
    returncode, output = capture(command, environment, log, timeout=rooms * 480 + 60, cancel=cancel)
    if returncode or 'SCRIPT ERROR:' in output or any(line.startswith('ERROR:') for line in output.splitlines()):
        raise RuntimeError(f'Browser witness failed: {command}; see {log}')
    return output

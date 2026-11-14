"""Bounded first-divergence shrinking for a failing P2P differential comparison.

When the P2P differential disagrees, this module reduces the submitted schedule
to a minimal failing scenario: it truncates at the operation the comparison
names, then greedily removes remaining operations while the differential keeps
disagreeing. Deliveries stay anchored to the operation that produced their
packet, so removing a producer also removes the deliveries that reference it,
and every surviving reference is re-ranked against the shortened schedule. All
candidates are built from the original operations and the original packet
counts, so a probe failure always means the candidate itself was wrong, never
that earlier bookkeeping drifted. The core never runs engines: a probe callable
decides whether a candidate still reproduces the disagreement, which keeps the
loop testable without Rust or Godot processes.
"""
import re

DEFAULT_BUDGET = 200
_OPERATION = re.compile(r'operation (\d+):')
_PACKET = re.compile(r'packet (\d+):')


def producer_op(packet_id, counts):
    """Operation index that produced the packet with this id, from per-operation outgoing counts."""
    produced = 0
    for index, count in enumerate(counts):
        if packet_id < produced + count:
            return index
        produced += count
    return None


def divergence_op(message, counts):
    """Operation index a comparison failure names; packet failures resolve through their producer."""
    match = _OPERATION.search(message)
    if match:
        return int(match.group(1))
    match = _PACKET.search(message)
    if match:
        return producer_op(int(match.group(1)), counts)
    return None


def with_cascades(operations, counts, removed):
    """Expand a removal set with deliveries anchored on removed producers, transitively."""
    removed = set(removed)
    changed = True
    while changed:
        changed = False
        for index, op in enumerate(operations):
            if index in removed or op['kind'] != 'deliver':
                continue
            producer = producer_op(op['packet'], counts)
            if producer is None or producer in removed:
                removed.add(index)
                changed = True
    return removed


def rewrite(operations, counts, removed):
    """Schedule without the removed operations, with surviving delivery ids re-ranked.

    Returns None when a delivery would still reference a packet whose producer
    was removed; callers cascade first, so this only fires on malformed input.
    """
    dropped_before = {}
    dropped_packets = 0
    for index in range(len(operations)):
        dropped_before[index] = dropped_packets
        if index in removed:
            dropped_packets += counts[index]
    schedule = []
    for index, op in enumerate(operations):
        if index in removed:
            continue
        if op['kind'] == 'deliver':
            producer = producer_op(op['packet'], counts)
            if producer is None or producer in removed:
                return None
            op = dict(op, packet=op['packet'] - dropped_before[producer])
        schedule.append(op)
    return schedule


def candidate(scenario, counts, removed):
    """Candidate scenario with the named operations removed, or None when malformed."""
    schedule = rewrite(scenario['operations'], counts, with_cascades(scenario['operations'], counts, removed))
    if schedule is None:
        return None
    return dict(scenario, operations=schedule)


def minimize(scenario, counts, failure, probe, budget=DEFAULT_BUDGET):
    """Reduce a failing scenario while a probe keeps reporting a disagreement.

    `probe(candidate)` returns the fresh failure message when the differential
    still disagrees, or None when the candidate passes or cannot execute.
    Rejected candidates are remembered by schedule signature so repeated passes
    never re-run the same probe. Returns the best scenario, its failure message
    and shrink statistics.
    """
    operations = scenario['operations']
    removed = set()
    best, message = scenario, failure
    stats = {'probes': 0, 'removed': 0, 'original_operations': len(operations), 'budget_exhausted': False}

    def signature(trial):
        return tuple((op['kind'], op.get('now_us'), op.get('packet'), op.get('peer')) for op in trial['operations'])

    rejected = set()
    index = divergence_op(failure, counts)
    if index is not None and 0 <= index < len(operations) - 1:
        trial = candidate(scenario, counts, set(range(index + 1, len(operations))))
        if trial is not None and signature(trial) not in rejected:
            stats['probes'] += 1
            observed = probe(trial)
            if observed is None:
                rejected.add(signature(trial))
            else:
                removed = with_cascades(operations, counts, set(range(index + 1, len(operations))))
                best, message = trial, observed
    while True:
        progressed = False
        for position in range(len(operations)):
            if position in removed:
                continue
            if stats['probes'] >= budget:
                stats['budget_exhausted'] = True
                break
            trial = candidate(scenario, counts, removed | {position})
            if trial is None:
                continue
            mark = signature(trial)
            if mark in rejected:
                continue
            stats['probes'] += 1
            observed = probe(trial)
            if observed is None:
                rejected.add(mark)
                continue
            removed = with_cascades(operations, counts, removed | {position})
            best, message = trial, observed
            progressed = True
        if not progressed or stats['budget_exhausted']:
            break
    stats['removed'] = len(removed)
    stats['final_operations'] = len(best['operations'])
    return best, message, stats

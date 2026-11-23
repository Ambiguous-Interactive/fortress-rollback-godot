"""Replay a candidate schedule on today's upstream before using any of its observations."""
import argparse
import gzip
import hashlib
import json
from itertools import accumulate
from pathlib import Path


HINTS = Path(__file__).with_name('fixtures') / 'p2p-schedules.json.gz'


def generation_inputs():
    root = HINTS.parents[3]
    oracle = root / 'scripts/oracle'
    paths = [*oracle.glob('p2p*.py'), oracle / 'contract.py', oracle / 'session_compare.py',
             *sorted((oracle / 'rust/src').rglob('*.rs')), oracle / 'rust/Cargo.lock', oracle / 'rust/Cargo.toml',
             root / 'docs/reference/pins.json']
    return {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(paths)}


def schedule_hints():
    if HINTS.exists():
        bundle = json.loads(gzip.decompress(HINTS.read_bytes()))
        if bundle['generation_inputs'] == generation_inputs():
            return bundle['cases']
    return {}


def builder_observer(binary, hint, observe):
    """Supply the validated upstream trace prefix for exactly matching builder operations."""
    if hint is None:
        return observe
    trace = observe(binary, hint)
    packets = list(accumulate((len(record['outgoing']) for record in trace['records']), initial=0))
    settings = {key: value for key, value in hint.items() if key != 'operations'}

    def prefix(executable, scenario):
        operations = scenario['operations']
        count = len(operations)
        if (executable != binary or operations != hint['operations'][:count]
                or settings != {key: value for key, value in scenario.items() if key != 'operations'}):
            return observe(executable, scenario)
        # Each record contains exactly that operation's outgoing packet IDs in emission order.
        return {**trace, 'scenario': scenario, 'records': trace['records'][:count], 'packets': trace['packets'][:packets[count]]}

    return prefix


def write_hints(cases):
    bundle = {'generation_inputs': generation_inputs(), 'cases': cases}
    data = json.dumps(bundle, sort_keys=True, separators=(',', ':')).encode()
    HINTS.write_bytes(gzip.compress(data, compresslevel=9, mtime=0))


if __name__ == '__main__':
    from p2p_launch import corpus
    parser = argparse.ArgumentParser(description='Regenerate the optional schedule hints from the pinned P2P oracle.')
    parser.add_argument('--binary', required=True, type=Path)
    write_hints(corpus(parser.parse_args().binary.resolve(strict=True), hints={}))

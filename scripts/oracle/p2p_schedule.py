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
    # The corpus builders and source trace validators share this adapter and locked build.
    paths = ('contract.py', 'p2p_capacity.py', 'p2p_contract.py', 'p2p_launch.py', 'p2p_lifecycle.py',
             'p2p_lifecycle_corpus.py', 'p2p_recovery.py', 'p2p_schedule.py', 'rust/src/bin/p2p.rs',
             'rust/Cargo.lock', 'rust/Cargo.toml', 'rust/rust-toolchain.toml')
    inputs = {str((oracle / path).relative_to(root)): hashlib.sha256((oracle / path).read_bytes()).hexdigest() for path in paths}
    pin_path = 'docs/reference/pins.json'
    pins = json.loads((root / pin_path).read_text(encoding='utf-8'))
    fortress = pins['sources']['fortress']
    p2p_pins = {
        'fortress': {field: fortress[field] for field in ('revision', 'root', 'archive')},
        'rust': {field: pins['rust'][field] for field in ('version', 'lockfile_sha256')},
    }
    inputs[pin_path] = hashlib.sha256(json.dumps(p2p_pins, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    return inputs


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

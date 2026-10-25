"""Executed pinned spectator startup and an explicit two-predicate model repair.

The reviewed upstream files remain immutable. The derived model removes only the
NULL-current-frame exception from backlog calculation. Its catch-up constant is
one for per-request Godot observations; actual multi-frame service cycles are
compared separately with Rust's real advance_frame requests.
"""
from copy import deepcopy
import json

from launch import ROOT, CACHE, digest, execute, load_manifest, setup_rust
from replay_launch import compare

ANCHORS = (
    'IF lastRecvFrame = NULL_FRAME \\/ currentFrame = NULL_FRAME',
    "IF lastRecvFrame' = NULL_FRAME \\/ currentFrame = NULL_FRAME",
)


def repair_model(source):
    for anchor in ANCHORS:
        if source.count(anchor) != 1:
            raise ValueError('pinned spectator startup predicate differs from reviewed anchor')
        source = source.replace(anchor, anchor.replace(' \\/ currentFrame = NULL_FRAME', ''))
    return source


def expected_rust(traces):
    return {'format': 1, 'traces': [
        {'capacity': trace['capacity'], 'preplay': trace['preplay'], 'speed': trace['speed'],
         'observations': trace['service_observations'], 'cycles': trace['cycles'], 'transcript': trace['transcript']}
        for trace in traces]}


def negative_controls(observed, expected):
    """Require exact comparison failures at real startup and first catch-up cycle."""
    compare(observed, expected)
    hidden = deepcopy(observed)
    hidden['traces'][0]['observations'][1]['backlog'] = 0
    wrong_speed = deepcopy(observed)
    wrong_speed['traces'][1]['cycles'][0]['steps'] = 1
    controls = [
        ('hidden-startup', hidden, 'result.traces[0].observations[1].backlog: value mismatch'),
        ('first-catchup', wrong_speed, 'result.traces[1].cycles[0].steps: value mismatch'),
    ]
    evidence = []
    for label, mutant, diagnostic in controls:
        try:
            compare(mutant, expected)
        except ValueError as error:
            if not str(error).startswith(diagnostic):
                raise ValueError(f'{label}: unexpected spectator diagnostic') from error
            evidence.append({'name': label, 'rejected': True, 'diagnostic': diagnostic})
        else:
            raise ValueError(f'{label}: spectator observer mutation survived')
    return evidence


def check_rust(traces, output):
    manifest = load_manifest()
    cargo, _ = setup_rust(manifest, False)
    execute([str(cargo), '+' + manifest['rust']['version'], 'build', '--locked', '--bin', 'spectator',
             '--manifest-path', str(ROOT / 'scripts/oracle/rust/Cargo.toml')], output / 'rust-build.log', timeout=600)
    binary = CACHE / 'target/debug/spectator'
    fingerprint = digest(binary)
    expected = expected_rust(traces)
    observations = []
    for repetition in range(2):
        stdout, stderr = execute([str(binary)], output / f'rust-{repetition}.log', timeout=60)
        if stderr.strip():
            raise ValueError('pinned spectator runtime emitted unexpected stderr')
        actual = json.loads(stdout)
        compare(actual, expected)
        observations.append(actual)
    compare(observations[0], observations[1])
    if digest(binary) != fingerprint:
        raise ValueError('pinned spectator oracle changed during observation')
    (output / 'rust-observed.json').write_text(json.dumps(observations[0], indent=2) + '\n')
    return {'complete': True, 'binary_sha256': fingerprint, 'workloads': len(traces), 'repetitions': 2,
            'observations_sha256': digest(output / 'rust-observed.json'),
            'negative_controls': negative_controls(observations[0], expected)}

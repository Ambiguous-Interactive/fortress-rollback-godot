"""Project observed Godot handshake states into the pinned bounded TLA trace checker."""
import json
from copy import deepcopy
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'reference'))
from fetch import digest
from launch import require_unchanged
from handshake_contract import strict_shape

def check(actual, output, jar, *, upstream, jar_digest):
    if digest(jar) != jar_digest:
        raise ValueError('TLC artifact hash mismatch')
    source = upstream / 'specs/tla/traces/sync-handshake-v1/matching.ndjson'
    checker = upstream / 'scripts/verification/verify-sync-handshake-traces.py'
    models = [upstream / name for name in ('specs/tla/SyncHandshakeV1.tla', 'specs/tla/SyncHandshakeV1Trace.tla')]
    dependencies = [source, checker, *models]
    before = {path: digest(path) for path in dependencies}
    scheduler = [json.loads(line) for line in source.read_text().splitlines()]
    rows = deepcopy(scheduler[:13])
    rows[0].update(trace='godot-observed-matching',
                   description='Observed production Godot p1 transitions; pinned scheduler supplies remote reply construction and transport duplication.')
    observed = [t for record in actual['records'] for t in record['transitions']]
    if observed[0]['action'] != 'begin_synchronization':
        raise ValueError('model projection missing begin')
    validate_begin(observed[0])
    observed = observed[1:]
    remaining = 2; phase = 'synchronizing'
    bindings = {}; accepted = []; mapping = [1, 3, 6, 7, 9, 10, 11]
    if len(observed) != len(mapping):
        raise ValueError('model projection unexpected observation count')
    dispositions = ['fresh', 'fresh', 'accepted', 'fresh', 'duplicate', 'accepted', 'not_synchronizing']
    for event, step, disposition in zip(observed, mapping, dispositions):
        row = rows[step + 1]
        if event['disposition'] != disposition or event['mismatch'] or event['timeout_sent']:
            raise ValueError('model projection unsupported runtime transition')
        expected_action = 'send_request' if row['action'] == 'SendSyncRequest' else 'handle_reply'
        if event['action'] != expected_action:
            raise ValueError('model projection scheduler/action disagreement')
        token = event['token']
        if expected_action == 'send_request':
            if event['remaining'] != remaining or event['state'] != phase:
                raise ValueError('observed send must preserve prior modeled phase/remaining')
            if token in bindings:
                raise ValueError('model projection raw token collision')
            bindings[token] = len(bindings) + 1
            message = row['updates']['network'][-1]
            if message['token'] != bindings[token]:
                raise ValueError('model projection token order')
        else:
            if token not in bindings:
                raise ValueError('model projection unknown raw reply')
            if disposition == 'accepted':
                accepted.append(bindings[token])
            expected_token = {6: 1, 9: 1, 10: 3, 11: 2}[step]
            if bindings[token] != expected_token:
                raise ValueError('model projection reply identity/order')
            remaining = event['remaining']; phase = event['state']
            row['updates']['syncRemaining']['p1'] = remaining
            row['updates']['phase']['p1'] = {'synchronizing': 'Syncing', 'running': 'Synced'}[event['state']]
            row['updates']['acceptedTokens']['p1'] = sorted(accepted)
    positive = output / 'godot-observed-matching.ndjson'
    positive.write_text('\n'.join(json.dumps(row) for row in rows) + '\n')
    negative = output / 'godot-observed-duplicate-decrement.ndjson'
    negative.write_text(json.dumps({'schema': 1, 'trace': 'godot-observed-duplicate-decrement', 'expect': 'reject',
        'description': 'Mutate the observed ignored duplicate reply into another decrement.', 'derived_from': positive.name,
        'mutation': {'step': 9, 'variable': 'syncRemaining', 'peer': 'p1', 'from': 1, 'to': 0}}) + '\n')
    command = ['python3', str(checker), '--jar', str(jar), str(positive), str(negative)]
    result = subprocess.run(command, capture_output=True, text=True, encoding='utf-8', timeout=120)
    (output / 'godot-observed-tlc.log').write_text(result.stdout + result.stderr)
    markers = ['PASS godot-observed-matching: accepted', 'PASS godot-observed-duplicate-decrement: rejected as required']
    if result.returncode != 0 or any(marker not in result.stdout for marker in markers):
        raise ValueError('TLC observation/control failed; inspect godot-observed-tlc.log')
    java = subprocess.run(['java', '-version'], capture_output=True, text=True, encoding='utf-8', timeout=20)
    if java.returncode:
        raise ValueError('Java version probe failed')
    require_unchanged('handshake formal sources', before, {path: digest(path) for path in dependencies})
    return {'complete': True, 'java_version': java.stdout + java.stderr,
            'model_sha256': {str(path.relative_to(upstream)): before[path] for path in models}, 'positive_sha256': digest(positive),
            'negative_sha256': digest(negative), 'TLC_sha256': jar_digest,
            'raw_token_mapping': bindings,
            'scheduler_sha256': before[source],
            'checker_sha256': before[checker]}


def validate_begin(value):
    expected = {'action': 'begin_synchronization', 'token': '', 'disposition': '', 'state': 'synchronizing', 'remaining': 2,
                'outstanding_request_count': 0, 'remote_connection': '', 'timeout_sent': False, 'mismatch': {}, 'elapsed_ms': -1}
    strict_shape(value, expected, 'formal begin')
    if value != expected:
        raise ValueError('formal begin must match complete initial snapshot')

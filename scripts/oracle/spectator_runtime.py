"""Replay actual Godot spectator observations through the pinned TLA Next relation.

Only the no-delay, one-step catch-up, binary-input subset is projected. The port's
next-frame boundary maps to the model's last-played frame. Synthetic sync steps
supply the model's handshake precondition; they do not establish runtime sync parity.
"""
from copy import deepcopy
import json
from pathlib import Path
import subprocess

from spectator_model import UPSTREAM, SPEC
from fetch import digest, load_manifest
from replay_launch import verified_engine

VARIABLES = ('sessionState', 'currentFrame', 'lastRecvFrame', 'inputBuffer', 'inputFrames',
             'hostConnection', 'syncProgress', 'framesBehind', 'inCatchupMode')


def integer(value, low, high):
    if type(value) is not int or not low <= value <= high:
        raise ValueError('invalid runtime spectator integer')
    return str(value)


def state(observation, capacity, phase='Running', sync=1):
    if not isinstance(observation, dict) or set(observation) != {'current', 'received', 'tags', 'inputs'}:
        raise ValueError('invalid runtime spectator snapshot')
    current = integer(observation['current'], -1, 11)
    received = integer(observation['received'], -1, 11)
    tags, rows = observation['tags'], observation['inputs']
    if not isinstance(tags, list) or not isinstance(rows, list) or len(tags) != capacity or len(rows) != capacity:
        raise ValueError('invalid runtime spectator ring')
    tag_function = ', '.join(f'{i} :> {integer(tag, -1, 11)}' for i, tag in enumerate(tags))
    values = []
    for i, row in enumerate(rows):
        if not isinstance(row, list) or len(row) != 2:
            raise ValueError('invalid runtime spectator inputs')
        values.append(f'{i} :> (1 :> {integer(row[0], 0, 1)} @@ 2 :> {integer(row[1], 0, 1)})')
    behind = 0 if observation['current'] == -1 or observation['received'] == -1 else max(0, observation['received'] - observation['current'])
    return ('[sessionState |-> "' + phase + '", currentFrame |-> ' + current + ', lastRecvFrame |-> ' + received +
            ', inputBuffer |-> (' + ' @@ '.join(values) + '), inputFrames |-> (' + tag_function.replace(', ', ' @@ ') +
            '), hostConnection |-> "Connected", syncProgress |-> ' + str(sync) + ', framesBehind |-> ' + str(behind) +
            ', inCatchupMode |-> ' + ('TRUE' if behind > 1 else 'FALSE') + ']')


def module(trace):
    if not isinstance(trace, dict) or set(trace) != {'capacity', 'observations', 'transcript'} or trace['capacity'] not in (2, 3):
        raise ValueError('invalid runtime spectator trace')
    capacity = trace['capacity']
    transcript = trace['transcript']
    if (type(capacity) is not int or not isinstance(transcript, list) or len(transcript) != 12
            or any(not isinstance(row, list) or len(row) != 3 or any(type(value) is not int for value in row) for row in transcript)
            or transcript != [[frame, frame % 2, 0] for frame in range(12)]):
        raise ValueError('runtime spectator callbacks differ from original input history')
    observations = trace['observations']
    if not isinstance(observations, list) or not 2 <= len(observations) <= 64:
        raise ValueError('invalid runtime spectator trace length')
    initial = {'current': -1, 'received': -1, 'tags': [-1] * capacity, 'inputs': [[0, 0] for _ in range(capacity)]}
    if observations[0] != initial or observations[-1]['current'] != 11:
        raise ValueError('runtime spectator trace missing initial/final boundary')
    states = [state(initial, capacity, 'Synchronizing', 0), state(initial, capacity, 'Synchronizing', 1)]
    states += [state(item, capacity) for item in observations]
    bindings = ',\n    '.join(f'{name} <- observed[cursor].{name}' for name in VARIABLES)
    text = ('---- MODULE SpectatorRuntime ----\nEXTENDS Integers, Sequences, TLC\nVARIABLE cursor\nobserved == <<\n' +
            ',\n'.join(states) + '\n>>\nModel == INSTANCE SpectatorSession WITH\n' +
            f'    NUM_PLAYERS <- 2, BUFFER_SIZE <- {capacity}, MAX_FRAMES_BEHIND <- 1, CATCHUP_SPEED <- 1, MAX_FRAME <- 11, NULL_FRAME <- -1,\n    ' +
            bindings + '\nInit == /\\ cursor = 1\n        /\\ Model!Init\n' +
            'Next == \\/ /\\ cursor < Len(observed)\n           /\\ cursor\' = cursor + 1\n           /\\ Model!Next\n' +
            '        \\/ /\\ cursor = Len(observed)\n           /\\ UNCHANGED cursor\n' +
            'Safety == Model!SafetyInvariant\n====\n')
    return text



def validate_bundle(value):
    if (not isinstance(value, list) or len(value) != 2
            or any(not isinstance(trace, dict) for trace in value)
            or [trace.get('capacity') for trace in value] != [2, 3]):
        raise ValueError('runtime spectator capacity inventory differs')
    for trace in value:
        module(trace)
    return value


def run_trace(trace, output, jar, label, expect_ok=True):
    directory = output / label
    directory.mkdir(parents=True, exist_ok=True)
    source = directory / 'SpectatorSession.tla'
    source.write_bytes((UPSTREAM / SPEC).read_bytes())
    generated = directory / 'SpectatorRuntime.tla'
    generated.write_text(module(trace))
    config = directory / 'SpectatorRuntime.cfg'
    config.write_text('INIT Init\nNEXT Next\nINVARIANT Safety\n')
    command = ['java', '-XX:+UseParallelGC', '-jar', str(jar), '-config', str(config.resolve()), '-workers', '1',
               '-metadir', str((directory / 'states').resolve()), str(generated.resolve())]
    result = subprocess.run(command, capture_output=True, text=True, encoding='utf-8', timeout=60)
    log = result.stdout + result.stderr
    (directory / 'tlc.log').write_text(log)
    if expect_ok:
        if result.returncode or 'No error has been found' not in log:
            raise ValueError(f'{label}: runtime spectator trace rejected; inspect tlc.log')
    elif result.returncode == 0 or 'Deadlock reached' not in log:
        raise ValueError(f'{label}: illegal spectator transition was not rejected as a deadlock')
    return {'passed': True, 'returncode': result.returncode, 'trace_sha256': digest(generated), 'model_sha256': digest(source)}


def check(engine, output, jar, root):
    output.mkdir(parents=True, exist_ok=True)
    command = [str(engine), '--headless', '--path', str(root), '--script', 'res://tests/oracle/spectator_trace.gd']
    engine_pin, engine_hash = verified_engine(Path(engine), load_manifest(), False)
    version = subprocess.check_output([str(engine), '--version'], text=True, encoding='utf-8', timeout=20).strip()
    if not version.startswith(engine_pin + '.stable'):
        raise ValueError('unsupported spectator engine profile')
    traces = []
    for repetition in range(2):
        result = subprocess.run(command, capture_output=True, text=True, encoding='utf-8', timeout=60)
        log = result.stdout + result.stderr
        (output / f'godot-{repetition}.log').write_text(log)
        marker = 'FORTRESS_SPECTATOR_TRACE '
        lines = [line[len(marker):] for line in result.stdout.splitlines() if line.startswith(marker)]
        if result.returncode or len(lines) != 1 or any(item in log for item in ('SCRIPT ERROR:', 'ERROR:', 'Parse Error:')):
            raise ValueError('runtime spectator observer failed')
        traces.append(validate_bundle(json.loads(lines[0])))
    if traces[0] != traces[1]:
        raise ValueError('runtime spectator traces do not repeat')
    (output / 'observed.json').write_text(json.dumps(traces[0], indent=2) + '\n')
    evidence = []
    for trace in traces[0]:
        positive = run_trace(trace, output, jar, f"capacity-{trace['capacity']}")
        # After receiving only frame zero, jump to frame one without its inputs.
        mutant = deepcopy(trace)
        mutant['observations'][1]['current'] = 1
        negative = run_trace(mutant, output, jar, f"capacity-{trace['capacity']}-illegal-advance", False)
        evidence.append({'capacity': trace['capacity'], 'positive': positive, 'illegal_advance': negative})
    if digest(Path(engine)) != engine_hash:
        raise ValueError('spectator engine changed during observation')
    return {'complete': True, 'traces': evidence, 'repetitions': 2, 'engine_version': version,
            'engine_sha256': engine_hash, 'observations_sha256': digest(output / 'observed.json')}

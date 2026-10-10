"""Persistent process-boundary mutations against real Rust and Godot executables."""
import copy
import json
import subprocess

from contract import checksum, initial_game_state


def mutate_load_state(trace):
    request = next(request for operation in trace['operations']
                   for request in operation['requests'] if request['kind'] == 'load')
    data = bytearray.fromhex(request['state_bytes'])
    data[4] ^= 1
    request.update(state_bytes=data.hex(), checksum=checksum(data))


def validate_load_failure(stdout, before_load):
    prefix = 'FORTRESS_ORACLE_GAME_RESULT '
    records = [json.loads(line[len(prefix):]) for line in stdout.splitlines() if line.startswith(prefix)]
    if len(records) != 1 or type(records[0].get('request_count')) is not int or records[0]['request_count'] != before_load:
        raise ValueError('load control failed outside the selected load boundary')
    errors = records[0].get('errors')
    if not isinstance(errors, list) or not any(isinstance(error, str) and 'state mismatch' in error for error in errors):
        raise ValueError('load control failed without canonical snapshot comparison')


def validate_game_failure(stdout, diagnostic, request_count=None):
    prefix = 'FORTRESS_ORACLE_GAME_RESULT '
    records = [json.loads(line[len(prefix):]) for line in stdout.splitlines() if line.startswith(prefix)]
    if len(records) != 1 or records[0].get('passed') is not False or records[0].get('complete') is not True:
        raise ValueError('game control lacks checked failure completion')
    errors = records[0].get('errors')
    if not isinstance(errors, list) or not any(isinstance(error, str) and diagnostic in error for error in errors):
        raise ValueError('game control failed without its intended diagnostic')
    if request_count is not None and (type(records[0].get('request_count')) is not int or records[0]['request_count'] != request_count):
        raise ValueError('game control failed outside its intended boundary')


def reject(command, log, environment, payload=None, expected_prefix=None, expected_exit=None):
    result = subprocess.run(command, input=payload, capture_output=True, text=True,
                            encoding='utf-8', timeout=30, env=environment)
    log.write_text(result.stdout + result.stderr)
    if result.returncode == 0 or (expected_exit is not None and result.returncode != expected_exit):
        raise ValueError(f'mutant accepted or failed for wrong reason; see {log}')
    if expected_prefix and expected_prefix not in result.stdout + result.stderr:
        raise ValueError(f'mutant lacks expected diagnostic; see {log}')
    if any(marker in result.stdout + result.stderr for marker in ('SCRIPT ERROR:', 'Parse Error:')):
        raise ValueError(f'mutant caused engine failure instead of checked rejection; see {log}')
    return result


def negative_controls(binary, engine_command, scenario, trace, directory, environment):
    scenario_mutations = {
        'version': lambda x: x.update(format=3),
        'revision': lambda x: x.update(upstream_revision='0' * 40),
        'empty_operations': lambda x: x.update(operations=[]),
        'empty_bytes': lambda x: x['operations'][2].update(bytes=''),
        'extra_fields': lambda x: x['operations'][0].update(ignored=True),
        'player_boundary': lambda x: x['operations'][2].update(player=256),
    }
    for name, mutate in scenario_mutations.items():
        value = copy.deepcopy(scenario)
        mutate(value)
        reject([str(binary)], directory / f'control-rust-{name}.log', environment,
               json.dumps(value), 'oracle:', 2)
    advance_operation = next(op for op in trace['operations'] if any(req['kind'] == 'load' for req in op['requests']))
    load_index = advance_operation['index']
    initial = initial_game_state(scenario['players'], scenario['format'])
    game_mutations = {
        'checksum': lambda x: x['final_state'].update(checksum='0' * 32),
        'state': lambda x: x['final_state'].update(bytes='00' * len(initial)),
        'load_state': mutate_load_state,
        'request_order': lambda x: x['operations'][load_index]['requests'].reverse(),
        'missing_operation': lambda x: x['operations'].pop(),
        'empty_operations': lambda x: x.update(
            scenario=dict(x['scenario'], operations=[]), operations=[], final_state={
                'frame': 0, 'bytes': initial.hex(),
                'checksum': checksum(initial)}),
        'unknown_fields': lambda x: x.update(unrecognized=True),
    }
    for name, mutate in game_mutations.items():
        value = copy.deepcopy(trace)
        mutate(value)
        path = directory / f'control-game-{name}.json'
        path.write_text(json.dumps(value) + '\n')
        result = reject(engine_command + ['--', '--trace', str(path.resolve())],
               directory / f'control-game-{name}.log', environment,
               expected_prefix='"passed":false', expected_exit=1)
        if name in ('state', 'checksum'):
            count = sum(len(op['requests']) for op in trace['operations'])
            validate_game_failure(result.stdout, 'state mismatch' if name == 'state' else 'checksum mismatch', count)
        elif name == 'empty_operations':
            validate_game_failure(result.stdout, 'scenario: empty or oversized operations', 0)
        if name == 'load_state':
            before_load = sum(len(op['requests']) for op in trace['operations'][:load_index])
            before_load += next(i for i, request in enumerate(advance_operation['requests']) if request['kind'] == 'load')
            validate_load_failure(result.stdout, before_load)
    return list(scenario_mutations) + list(game_mutations)

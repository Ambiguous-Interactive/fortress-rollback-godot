"""Persistent process-boundary mutations against real Rust and Godot executables."""
import copy
import json
import subprocess

from contract import checksum


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


def negative_controls(binary, engine_command, scenario, trace, directory, environment):
    scenario_mutations = {
        'version': lambda x: x.update(format=2),
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
    game_mutations = {
        'checksum': lambda x: x['final_state'].update(checksum='0' * 32),
        'state': lambda x: x['final_state'].update(bytes='00' * (4 * (scenario['players'] + 1))),
        'load_state': lambda x: x['operations'][load_index]['requests'][0].update(state_bytes='00' * (4 * (scenario['players'] + 1))),
        'request_order': lambda x: x['operations'][load_index]['requests'].reverse(),
        'missing_operation': lambda x: x['operations'].pop(),
        'empty_operations': lambda x: x.update(
            scenario=dict(x['scenario'], operations=[]), operations=[], final_state={
                'frame': 0, 'bytes': '00' * (4 * (scenario['players'] + 1)),
                'checksum': checksum(bytes(4 * (scenario['players'] + 1)))}),
        'unknown_fields': lambda x: x.update(unrecognized=True),
    }
    for name, mutate in game_mutations.items():
        value = copy.deepcopy(trace)
        mutate(value)
        path = directory / f'control-game-{name}.json'
        path.write_text(json.dumps(value) + '\n')
        reject(engine_command + ['--', '--trace', str(path.resolve())],
               directory / f'control-game-{name}.log', environment,
               expected_prefix='"passed":false', expected_exit=1)
    return list(scenario_mutations) + list(game_mutations)

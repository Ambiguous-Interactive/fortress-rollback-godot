"""Persistent lifecycle controls attack actual observed bytes and terminal projection."""
from copy import deepcopy
import json
from pathlib import Path
import sys
from launch import execute
from p2p_contract import compare, validate
from controls import reject
from run import rust_environment


def unfreeze(mutant, index, expected):
    from contract import advance_game_state, checksum
    record = mutant['records'][index]
    source = expected['records'][index]
    if source['frame_after'] != record['frame_before']:
        for key in ('requests', 'state', 'frame_after'):
            record[key] = deepcopy(source[key])
        return
    before = bytes.fromhex(record['state']); frame = record['frame_before']
    players = mutant['scenario']['players']
    after = advance_game_state(before, [0] * players, 2)
    record['requests'] = [
        {'kind': 'save', 'frame': frame, 'state_bytes': before.hex(), 'checksum': checksum(before), 'inputs': []},
        {'kind': 'advance', 'frame': frame, 'state_bytes': after.hex(), 'checksum': checksum(after),
         'inputs': [{'player': peer, 'bytes': '00000000', 'status': 'predicted'} for peer in range(players)]}]
    record.update(state=after.hex(), frame_after=frame + 1)


def mutations_for(actual, expected):
    """Declare diagnostics before invoking the validator; never learn from failures."""
    mutations = {
        'metric_bool': (lambda x: x['records'][0]['metrics'].update(frames_ahead=False), 'frames ahead: invalid integer'),
        'pre_state': (lambda x: x['records'][0].update(pre_state='00' * len(bytes.fromhex(x['records'][0]['pre_state']))), 'lifecycle pre state')}
    for index, packet in enumerate(actual['packets']):
        if packet['semantic']['kind'] == 'quality_report':
            diagnostic = f'packet {index}: semantic mismatch'
            mutations['quality_advantage'] = (lambda x, i=index: x['packets'][i]['semantic'].update(frame_advantage=32767), diagnostic)
            mutations['quality_ping'] = (lambda x, i=index: x['packets'][i]['semantic'].update(ping='00' * 16), diagnostic)
            break
    for kind, field, name in [('quality_reply', 'pong', 'quality_pong'), ('checksum_report', 'checksum', 'checksum_payload')]:
        packet = next((p for p in actual['packets'] if p['semantic']['kind'] == kind), None)
        if packet is not None:
            index = packet['id']
            mutations[name] = (lambda x, i=index, f=field: x['packets'][i]['semantic'].update({f: '00' * 16}),
                               f'packet {index}: semantic mismatch')
    for index, record in enumerate(actual['records']):
        available = next((m for m in record['metrics']['peers'] if m['error'] is None and m['ping'] > 0), None)
        if available is not None and 'measured_rtt' not in mutations:
            offset = record['metrics']['peers'].index(available)
            mutations['measured_rtt'] = (lambda x, i=index, j=offset: x['records'][i]['metrics']['peers'][j].update(
                ping=x['records'][i]['metrics']['peers'][j]['ping'] + 1), f'operation {index}: metrics mismatch')
        for offset, event in enumerate(record['events']):
            if event['kind'] == 'network_resumed':
                mutations['resume_event'] = (lambda x, i=index, j=offset: x['records'][i]['events'].pop(j), f'operation {index}: events mismatch')
            if event['kind'] == 'wait_recommendation':
                mutations['wait_payload'] = (lambda x, i=index, j=offset: x['records'][i]['events'][j].update(
                    skip_frames=x['records'][i]['events'][j]['skip_frames'] + 1), f'operation {index}: events mismatch')
            if event['kind'] == 'network_interrupted':
                mutations['notify_payload'] = (lambda x, i=index, j=offset: x['records'][i]['events'][j].update(disconnect_timeout=1),
                                               f'operation {index}: events mismatch')
            if event['kind'] in {'disconnected', 'desync_detected'}:
                mutations['terminal_peer'] = (lambda x, i=index, j=offset: x['records'][i]['events'][j].update(peer=x['records'][i]['peer']),
                                              f'operation {index}: terminal trigger mismatch')
                mutations['terminal_earlier'] = (lambda x, i=index, j=offset: x['records'][0]['events'].append(deepcopy(x['records'][i]['events'][j])),
                                                 'terminal projection requires first final trigger')
                mutations['terminal_unfrozen'] = (lambda x, i=index: unfreeze(x, i, expected),
                                                  f'operation {index}: Godot terminal boundary not frozen')
                mutations['invented_self_extension'] = (lambda x, i=index: x['records'][i]['extension_events'].append(
                    {'kind': 'disconnected', 'peer': x['records'][i]['peer'], 'reason': 255}), 'terminal extension outside final desync policy')
                if event['kind'] == 'desync_detected':
                    mutations['desync_frame'] = (lambda x, i=index, j=offset: x['records'][i]['events'][j].update(frame=x['records'][i]['events'][j]['frame'] + 1),
                                                 f'operation {index}: terminal trigger mismatch')
                    for key in ('local_checksum', 'remote_checksum'):
                        mutations['desync_' + key] = (lambda x, i=index, j=offset, k=key: x['records'][i]['events'][j].update({k: '00' * 16}),
                                                      f'operation {index}: terminal trigger mismatch')
                    mutations['duplicate_remote_extension'] = (lambda x, i=index: x['records'][i]['extension_events'].append(
                        deepcopy(next(e for e in x['records'][i]['extension_events'] if e['kind'] == 'disconnected'))),
                        f'operation {index}: terminal extension membership')
                    def duplicate_goodbye(x, i=index):
                        packet = deepcopy(x['packets'][-1]); packet['id'] = len(x['packets'])
                        x['packets'].append(packet); x['records'][i]['outgoing'].append(packet['id'])
                    mutations['duplicate_goodbye'] = (duplicate_goodbye, f'operation {index}: terminal goodbye membership/count')
    return mutations


def controls(actual, expected, scenario):
    mutations = mutations_for(actual, expected)
    for name, (mutate, diagnostic) in mutations.items():
        mutant = deepcopy(actual); mutate(mutant)
        try:
            compare(mutant, expected, scenario)
        except ValueError as error:
            if not str(error).startswith(diagnostic):
                raise ValueError('lifecycle control wrong boundary: ' + name + ': ' + str(error)) from error
        else:
            raise ValueError('lifecycle control survived: ' + name)
    return list(mutations)


def wire_controls(binary, engine, scenarios, directory):
    root = Path(__file__).resolve().parents[2]
    observer = (root / 'tests/oracle/p2p_trace.gd').read_text(encoding='utf-8')
    boundary = '\t\tvar message: T.Message = result.message\n'
    if observer.count(boundary) != 1:
        raise ValueError('lifecycle observer control boundary changed')
    result = []
    for case, kind, field, mutation in [
        ('quality_echo_resume', 'QUALITY_REPORT', 'ping', 'message.token[0] ^= 1'),
        ('quality_echo_resume', 'QUALITY_REPLY', 'pong', 'message.token[0] ^= 1'),
        ('checksums_match', 'CHECKSUM_REPORT', 'checksum', 'message.checksum[0] ^= 1'),
    ]:
        if case not in scenarios:
            continue
        scenario = scenarios[case]
        expected = json.loads((directory / (case + '-source.json')).read_text(encoding='utf-8'))
        index = next(p['id'] for p in expected['packets'] if p['semantic']['kind'] == {'ping': 'quality_report', 'pong': 'quality_reply', 'checksum': 'checksum_report'}[field])
        insertion = boundary + f'''\t\tif message.kind == T.Kind.{kind} and not lifecycle_wire_mutated:
\t\t\tlifecycle_wire_mutated = true
\t\t\t{mutation}
\t\t\tvar encoded_control: T.Result = Codec.encode(message, limits)
\t\t\tif encoded_control.code != T.Code.OK:
\t\t\t\t_fail("lifecycle wire encode")
\t\t\t\treturn false
\t\t\tvar decoded_control: T.Result = Codec.decode(encoded_control.bytes, limits)
\t\t\tif decoded_control.code != T.Code.OK:
\t\t\t\t_fail("lifecycle wire decode")
\t\t\t\treturn false
\t\t\tmessage = decoded_control.message
\t\t\tprint("FORTRESS_P4_WIRE " + JSON.stringify(Lifecycle.semantic(message)))
'''
        script = directory / ('control-p4-wire-' + field + '.gd')
        script.write_text(observer.replace('var limits: T.Limits', 'var lifecycle_wire_mutated: bool = false\nvar limits: T.Limits').replace(boundary, insertion), encoding='utf-8')
        submitted = directory / (case + '-scenario.json')
        stdout, stderr = execute([str(engine.resolve()), '--headless', '--path', str(root), '--script', str(script.resolve()),
                                  '--', '--scenario', str(submitted.resolve())], directory / ('control-p4-wire-' + field + '.log'))
        from p2p_launch import parse_godot
        actual = parse_godot(stdout, stderr); validate(actual, scenario)
        try:
            compare(actual, expected, scenario)
        except ValueError as error:
            if not str(error).startswith(f'packet {index}: semantic mismatch'):
                raise ValueError('lifecycle wire wrong rejection boundary') from error
        else:
            raise ValueError('lifecycle encoded wire mutant escaped observer')
        proof = [json.loads(line[len('FORTRESS_P4_WIRE '):]) for line in stdout.splitlines() if line.startswith('FORTRESS_P4_WIRE ')]
        if proof != [actual['packets'][index]['semantic']]:
            raise ValueError('lifecycle encoded wire mutation proof')
        result.append('actual_encoded_p4_' + field + '_rejected')
    return result


def wide_token_controls(binary, expected, directory, environment):
    """Positive raw-message u128 boundaries and strict serde rejection controls."""
    result = []
    for kind, variant, field in [('quality_report', 'QualityReport', 'ping'), ('quality_reply', 'QualityReply', 'pong')]:
        index = next(p['id'] for p in expected['packets'] if p['semantic']['kind'] == kind)
        for number in [1 << 64, (1 << 127) + 17, (1 << 128) - 1]:
            trace = deepcopy(expected)
            trace['packets'][index]['raw']['body'][variant][field] = number
            trace['packets'][index]['semantic'][field] = f'{number:032x}'
            validate(trace, trace['scenario'], True)
            label = 'positive-p4-' + field + '-u128-' + str(number)
            payload = json.dumps(trace)
            (directory / (label + '.json')).write_text(payload + '\n', encoding='utf-8')
            stdout, stderr = execute([str(binary), '--validate-trace'], directory / (label + '.log'), payload)
            value = json.loads(stdout)
            if (stderr or type(value) is not dict or set(value) != {'complete', 'packets'} or value['complete'] is not True
                    or type(value['packets']) is not int or value['packets'] != len(expected['packets'])):
                raise ValueError('positive wide token boundary failed: ' + label)
            result.append(label.replace('-', '_'))
        for name, alias in [('bool', True), ('float', 17.0), ('string', '17'), ('null', None), ('negative', -1), ('overflow', 1 << 128)]:
            trace = deepcopy(expected)
            trace['packets'][index]['raw']['body'][variant][field] = alias
            label = 'control-p4-' + field + '-u128-' + name
            payload = json.dumps(trace)
            (directory / (label + '.json')).write_text(payload + '\n', encoding='utf-8')
            reject([str(binary), '--validate-trace'], directory / (label + '.log'), environment, payload, 'p2p oracle:', 2)
            result.append('standalone_p4_' + field + '_u128_' + name + '_rejected')
    return result


def process_controls(binary, engine, scenarios, directory):
    root = Path(__file__).resolve().parents[2]; environment = rust_environment(); result = []
    if 'quality_echo_resume' in scenarios:
        expected = json.loads((directory / 'quality_echo_resume-source.json').read_text(encoding='utf-8'))
        result.extend(wide_token_controls(binary, expected, directory, environment))
        original = scenarios['quality_echo_resume']
        mutant = deepcopy(original); mutant['lifecycle'] = None
        path = directory / 'control-p4-present-lifecycle-null.json'
        payload = json.dumps(mutant); path.write_text(payload + '\n')
        reject([str(binary)], directory / 'control-p4-present-lifecycle-null-rust.log', environment, payload, 'p2p oracle:', 2)
        reject([str(engine.resolve()), '--headless', '--path', str(root), '--script', 'res://tests/oracle/p2p_trace.gd',
                '--', '--scenario', str(path.resolve())], directory / 'control-p4-present-lifecycle-null-godot.log', environment,
               expected_prefix='FORTRESS_P2P_ERROR invalid scenario', expected_exit=2)
        result.append('standalone_p4_present_lifecycle_null')
        for key in original['lifecycle']:
            for name, alias in [('bool', True), ('float', float(original['lifecycle'][key])), ('null', None)]:
                mutant = deepcopy(original); mutant['lifecycle'][key] = alias
                label = 'p4_' + key + '_' + name; payload = json.dumps(mutant)
                path = directory / ('control-' + label + '.json'); path.write_text(payload + '\n')
                reject([str(binary)], directory / ('control-' + label + '-rust.log'), environment, payload, 'p2p oracle:', 2)
                reject([str(engine.resolve()), '--headless', '--path', str(root), '--script', 'res://tests/oracle/p2p_trace.gd',
                        '--', '--scenario', str(path.resolve())], directory / ('control-' + label + '-godot.log'), environment,
                       expected_prefix='FORTRESS_P2P_ERROR invalid scenario', expected_exit=2)
                result.append('standalone_' + label)
    for case, scenario in scenarios.items():
        if 'lifecycle' not in scenario:
            continue
        actual = json.loads((directory / (case + '-actual.json')).read_text(encoding='utf-8'))
        expected = json.loads((directory / (case + '-source.json')).read_text(encoding='utf-8'))
        command = [sys.executable, str(Path(__file__).with_name('p2p_validate.py')), '--scenario',
                   str(directory / (case + '-scenario.json')), '--expected', str(directory / (case + '-source.json'))]
        for name, (mutate, diagnostic) in mutations_for(actual, expected).items():
            mutant = deepcopy(actual); mutate(mutant)
            try:
                compare(mutant, expected, scenario)
            except ValueError as error:
                if not str(error).startswith(diagnostic):
                    raise ValueError('lifecycle process control wrong boundary: ' + name + ': ' + str(error)) from error
            else:
                raise ValueError('lifecycle process control survived ' + name)
            label = case + '-' + name; payload = json.dumps(mutant)
            (directory / ('control-' + label + '.json')).write_text(payload + '\n')
            reject(command, directory / ('control-' + label + '.log'), environment, payload, 'p2p validation: ' + diagnostic, 2)
            result.append('trace_' + label)
    if 'control_boundaries' in scenarios:
        from p2p_lifecycle import CORPUS_REQUIREMENTS
        short = deepcopy(scenarios['control_boundaries']); short['operations'] = short['operations'][:1]
        actual = json.loads((directory / 'control_boundaries-actual.json').read_text())
        expected = json.loads((directory / 'control_boundaries-source.json').read_text())
        for trace in (actual, expected):
            trace.update(scenario=deepcopy(short), records=trace['records'][:1], packets=[])
        compare(actual, expected, short)
        submitted = directory / 'control-p4-vacuous-scenario.json'; submitted.write_text(json.dumps(short))
        reference = directory / 'control-p4-vacuous-source.json'; reference.write_text(json.dumps(expected))
        payload = json.dumps(actual)
        (directory / 'control-p4-vacuous-actual.json').write_text(payload)
        for case, (observations, _) in CORPUS_REQUIREMENTS.items():
            command = [sys.executable, str(Path(__file__).with_name('p2p_validate.py')), '--scenario', str(submitted),
                       '--expected', str(reference), '--corpus-case', case]
            diagnostic = 'p2p validation: corpus ' + case + ': missing required source observation ' + observations.split()[0]
            reject(command, directory / ('control-p4-vacuous-' + case + '.log'), environment, payload, diagnostic, 2)
            result.append('named_corpus_' + case + '_vacuous_rejected')
    result.extend(wire_controls(binary, engine, scenarios, directory))
    return result

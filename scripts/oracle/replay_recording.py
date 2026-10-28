"""Actual pinned P2PSession recording, portable export and sequential playback applicability."""
import copy
import hashlib
import json

from replay_launch import advance, compare, expected as playback_expected, state_bytes


def corpus():
    return [dict(name=f'record-{players}p-{count}-delay{delay}' + ('-prediction0' if prediction == 0 else ''),
                 players=players, count=count, delay=delay, prediction=prediction, seed=0xffffffff)
            for prediction in (2, 0) for players in range(2, 9) for count in (0, 1, 7, 64) for delay in (0, 2)]


def expected(case, rust):
    count, delay, players = case['count'], case['delay'], case['players']
    lockstep = case['prediction'] == 0
    recorded = (max(delay + 1, count + delay - 1) if delay and count else count) if rust and lockstep else (
        (count - 1 + delay if count >= 2 else 0) if rust else count)
    rows = [[0 if frame < delay else (case['seed'] + (frame - delay) * 1234567 + slot * 0x1020304) & 0xffffffff
             for slot in range(players)] for frame in range(max(count, recorded))]
    state = (0, case['seed'], case['seed'], 0)
    boundaries, advances, records, services = [], [], [], []
    for row in rows:
        boundaries.append(state_bytes(state).hex())
        frame = state[0]
        if frame < count and not lockstep:
            saved = dict(kind='save', frame=frame, bytes=boundaries[-1], inputs=[])
            if rust and frame == 0:
                records.append(copy.deepcopy(saved))
            records.append(saved)
        state = advance(state, row)
        advances.append(state_bytes(state).hex())
        if frame < count:
            records.append(dict(kind='advance', frame=frame, bytes=advances[-1],
                                inputs=[dict(value=value, status='confirmed') for value in row]))
            if rust and lockstep and (delay == 0 or frame == 0):
                services.append(dict(before=frame, after=frame, requests=[]))
            requests = ['advance'] if lockstep else (['save', 'save', 'advance'] if rust and frame == 0 else ['save', 'advance'])
            services.append(dict(before=frame, after=frame + 1, requests=requests))
    checksums = [boundaries[frame] if not lockstep and (not rust or delay == 0 or frame == 0) else None for frame in range(recorded)]
    playback = playback_expected(dict(name=case['name'], players=players, seed=case['seed'], validate=True,
                                      frames=rows[:recorded], checksums=checksums), rust)
    return dict(name=case['name'], players=players, total_frames=recorded, skipped=0, frames=rows[:recorded],
                checksums=checksums, records=records, advances=advances[:count], saves=[] if lockstep else ([0] if rust and count else []) + list(range(count)),
                services=services, playback=playback)


def acceptance(observed):
    """Require all roster/delay/length boundaries even if a changed generator agrees with itself."""
    names = [f'record-{players}p-{count}-delay{delay}' + suffix for suffix in ('', '-prediction0')
             for players in range(2, 9) for count in (0, 1, 7, 64) for delay in (0, 2)]
    for runtime in ('rust', 'godot'):
        cases = observed[runtime]['cases']
        if sorted(case['name'] for case in cases) != sorted(names):
            raise ValueError(f'{runtime}: incomplete recording workload inventory')
        for case in cases:
            # Reconstruct workload dimensions from the independently required name, not output metadata.
            _, roster, length, delayed, *mode = case['name'].split('-')
            specification = dict(name=case['name'], players=int(roster[:-1]), count=int(length),
                                 delay=int(delayed[5:]), prediction=0 if mode else 2, seed=0xffffffff)
            compare(case, expected(specification, runtime == 'rust'), f'recording.{runtime}.{case["name"]}')
    return names


def observe(binary, engine, root, output, execute):
    cases = corpus()
    scenario = json.dumps(cases, indent=2) + '\n'
    fixture = output / 'recording-cases.json'
    fixture.write_text(scenario)
    observations = []
    command = [str(engine), '--headless', '--path', str(root), '--script', 'res://tests/oracle/replay_session_trace.gd',
               '--', '--recording', str(fixture.resolve())]
    for repeat in (1, 2):
        combined = {runtime: dict(format=1, cases=[]) for runtime in ('rust', 'godot')}
        for prediction in (2, 0):
            partition = [case for case in cases if case['prediction'] == prediction]
            text = json.dumps(partition, indent=2) + '\n'
            part_file = output / f'recording-prediction{prediction}.json'
            part_file.write_text(text)
            stdout, stderr = execute([str(binary), '--recording'], output / f'recording-rust-{repeat}-prediction{prediction}.log', text)
            if stderr.strip():
                raise ValueError('Rust recording emitted unexpected stderr')
            rust = json.loads(stdout)
            stdout, stderr = execute(command[:-1] + [str(part_file.resolve())], output / f'recording-godot-{repeat}-prediction{prediction}.log')
            if any(marker in stdout + stderr for marker in ('SCRIPT ERROR:', 'ERROR:', 'Parse Error:')):
                raise ValueError('Godot recording engine error')
            prefix = 'FORTRESS_REPLAY_RESULT '
            lines = [line[len(prefix):] for line in stdout.splitlines() if line.startswith(prefix)]
            if len(lines) != 1:
                raise ValueError('missing or duplicate recording completion')
            for runtime, actual in [('rust', rust), ('godot', json.loads(lines[0]))]:
                compare(actual, dict(format=1, cases=[expected(case, runtime == 'rust') for case in partition]), f'recording.{runtime}')
                combined[runtime]['cases'].extend(actual['cases'])
        for runtime, actual in combined.items():
            wanted = dict(format=1, cases=[expected(case, runtime == 'rust') for case in cases])
            compare(actual, wanted, f'recording.{runtime}')
        observations.append(combined)
    compare(observations[0], observations[1])
    workloads = acceptance(observations[0])
    negative = controls(observations[0])
    rejections = standalone_controls(binary, command, output, execute)
    return dict(workloads=workloads, cases_sha256=hashlib.sha256(fixture.read_bytes()).hexdigest(),
                negative_controls=negative, standalone_rejections=rejections, observations=observations[0],
                extraction=observe_extraction(binary, command, output, execute))


def standalone_controls(binary, command, output, execute):
    """Actual standalone parsers reject altered tokens beside an integer-token green control."""
    valid = dict(name='integer-token-control { "players": 2.0 } \\ escaped', players=2, count=1, delay=0, prediction=2, seed=0xffffffff)
    results = []
    for runtime in ('rust', 'godot'):
        def invoke(text, name):
            log = output / f'recording-{runtime}-{name}.log'
            fixture = output / f'recording-{runtime}-{name}.json'
            fixture.write_text(text)
            invocation = [str(binary), '--recording'] if runtime == 'rust' else command[:-1] + [str(fixture.resolve())]
            return invocation, log, text if runtime == 'rust' else None

        def accept(text, name, specification=valid):
            invocation, log, text = invoke(text, name)
            stdout, stderr = execute(invocation, log, text)
            if runtime == 'godot':
                lines = [line.removeprefix('FORTRESS_REPLAY_RESULT ') for line in stdout.splitlines()
                         if line.startswith('FORTRESS_REPLAY_RESULT ')]
                if len(lines) != 1 or any(marker in stdout + stderr for marker in ('SCRIPT ERROR:', 'ERROR:', 'Parse Error:')):
                    raise ValueError('invalid standalone green control')
                stdout = lines[0]
            elif stderr.strip():
                raise ValueError('Rust standalone green control stderr')
            compare(json.loads(stdout), dict(format=1, cases=[expected(specification, runtime == 'rust')]), f'{runtime}.{name}')

        accept(json.dumps([valid], indent=2), 'integer-control')
        for field, limits in [('players', (2, 8)), ('count', (0, 64)), ('delay', (0, 2)), ('seed', (0, 0xffffffff))]:
            for value in limits:
                specification = dict(valid, **{field: value})
                accept(json.dumps([specification]), f'{field}-{value}-integer-control', specification)
        cases = [('dimensions', json.dumps([dict(valid, count=65)]),
                  'invalid recording dimensions' if runtime == 'rust' else 'invalid recording case')]
        for field in ('players', 'count', 'delay', 'prediction', 'seed'):
            for kind, token in [('decimal', str(valid[field]) + '.0'), ('exponent', str(valid[field]) + 'e0'), ('bool', 'true'),
                                ('leading-zero', '0' + str(valid[field])), ('positive-sign', '+' + str(valid[field])),
                                ('negative-zero', '-0'), ('negative', '-' + str(max(1, valid[field])))]:
                altered = json.dumps([valid]).replace(f'"{field}": {valid[field]}', f'"{field}": {token}')
                if runtime == 'rust':
                    diagnostic = {'leading-zero': 'invalid number', 'positive-sign': 'expected value',
                                  'negative': 'invalid value'}.get(kind, 'invalid type')
                else:
                    diagnostic = ('invalid recording case' if kind == 'bool' else
                                  'invalid unsigned token' if kind in ('negative', 'negative-zero') else 'invalid integer token')
                cases.append((f'{field}-{kind}', altered, diagnostic))
        for kind, token, rust_diagnostic in [
            ('trailing-dot', '1.', 'invalid number'), ('leading-dot', '.1', 'expected value'),
            ('incomplete-exponent', '1e', 'invalid number'), ('incomplete-exponent-sign', '1e+', 'invalid number'),
            ('bare-minus', '-', 'invalid number'), ('double-minus', '--1', 'invalid number')
        ]:
            altered = json.dumps([valid]).replace('"count": 1', '"count": ' + token)
            cases.append((kind, altered, rust_diagnostic if runtime == 'rust' else 'invalid integer token'))
        for field in valid:
            raw = json.dumps([valid], indent=2)
            escaped_key = '"\\u%04x%s"' % (ord(field[0]), field[1:])
            accept(raw.replace(json.dumps(field) + ':', escaped_key + ':'), f'{field}-escaped-key-control')
            for spelling, key in [('literal', json.dumps(field)), ('escaped', escaped_key)]:
                altered = raw.replace('{', '{' + key + ': ' + json.dumps(valid[field]) + ',', 1)
                diagnostic = 'duplicate field' if runtime == 'rust' else 'duplicate object key'
                cases.append((f'{field}-duplicate-{spelling}', altered, diagnostic))
        for name, invalid, diagnostic in cases:
            invocation, log, text = invoke(invalid, name)
            try:
                execute(invocation, log, text)
            except ValueError:
                observed = log.read_text()
                if diagnostic not in observed or 'FORTRESS_REPLAY_RESULT ' in observed:
                    raise ValueError(f'{runtime}-{name}: wrong standalone recording rejection')
            else:
                raise ValueError(f'{runtime}-{name}: invalid recording accepted')
            results.append(f'{runtime}-{name}')
    return results


def controls(observed):
    """Paired mutations preserve valid history except for the named recording contract."""
    results = []
    for runtime in ('rust', 'godot'):
        for fault in ('missing-player', 'input-order', 'checksum-coverage', 'prefix-length', 'canonical-state', 'playback-state',
                      'original-status', 'original-value', 'original-save-state', 'original-order', 'original-missing-save', 'original-unexpected-load'):
            changed = copy.deepcopy(observed)
            case = next(case for case in changed[runtime]['cases'] if case['name'] == 'record-5p-64-delay2')
            original_index = next(i for i, record in enumerate(case['records'])
                                  if record['frame'] == 31 and record['kind'] == ('advance' if fault in ('original-status', 'original-value') else 'save'))
            fields = {'missing-player': 'frames[32]', 'input-order': 'frames[31]', 'checksum-coverage': 'checksums[1]',
                      'prefix-length': 'frames', 'canonical-state': 'advances[31]', 'playback-state': 'playback.records[31].bytes'}
            if fault.startswith('original-'):
                record = case['records'][original_index]
                fields[fault] = f'records[{original_index}]'
                if fault == 'original-status':
                    record['inputs'][2]['status'] = 'predicted'
                    fields[fault] += '.inputs[2].status'
                elif fault == 'original-value':
                    record['inputs'][2]['value'] ^= 1
                    fields[fault] += '.inputs[2].value'
                elif fault == 'original-save-state':
                    record['bytes'] = '00' * 16
                    fields[fault] += '.bytes'
                elif fault == 'original-order':
                    case['records'][original_index:original_index + 2] = reversed(case['records'][original_index:original_index + 2])
                elif fault == 'original-unexpected-load':
                    case['records'].insert(original_index, dict(record, kind='load'))
                    fields[fault] = 'records'
                else:
                    case['records'].pop(original_index)
                    fields[fault] = 'records'
            elif fault == 'missing-player':
                case['frames'][32].pop(2)
            elif fault == 'input-order':
                case['frames'][31], case['frames'][32] = case['frames'][32], case['frames'][31]
            elif fault == 'checksum-coverage':
                case['checksums'][1] = '00' * 16 if case['checksums'][1] is None else None
            elif fault == 'prefix-length':
                case['frames'].pop()
            elif fault == 'canonical-state':
                case['advances'][31] = '00' * 16
            else:
                case['playback']['records'][31]['bytes'] = '00' * 16
            try:
                acceptance(changed)
            except ValueError as error:
                if f'recording.{runtime}.{case["name"]}.{fields[fault]}' not in str(error):
                    raise ValueError(f'{fault}: wrong recording rejection: {error}') from error
                results.append(f'{runtime}-{fault}')
            else:
                raise ValueError(f'{runtime}-{fault}: recording mutation accepted')
        for delay in (0, 2):
            for fault in ('service-omission', 'fabricated-checksum', 'resampled-input', 'premature-target'):
                changed = copy.deepcopy(observed)
                case = next(case for case in changed[runtime]['cases'] if case['name'] == f'record-5p-64-delay{delay}-prediction0')
                field = 'services'
                if fault == 'service-omission':
                    case['services'].pop(0)
                elif fault == 'fabricated-checksum':
                    case['checksums'][0] = '00' * 16
                    field = 'checksums[0]'
                elif fault == 'resampled-input':
                    case['frames'][31][2] ^= 1
                    field = 'frames[31][2]'
                else:
                    case['services'][-1]['after'] -= 1
                    field = f'services[{len(case["services"]) - 1}].after'
                try:
                    acceptance(changed)
                except ValueError as error:
                    if f'recording.{runtime}.{case["name"]}.{field}' not in str(error):
                        raise ValueError(f'{fault}: wrong lockstep recording rejection: {error}') from error
                    results.append(f'{runtime}-delay{delay}-{fault}')
                else:
                    raise ValueError(f'{runtime}-delay{delay}-{fault}: lockstep recording mutation accepted')
    return results



def extraction_corpus():
    return [dict(name=f'extract-{players}p-{count}-delay{delay}-prediction{prediction}',
                 players=players, count=count, delay=delay, prediction=prediction, seed=0xffffffff)
            for players in range(2, 9) for count in (7, 64) for delay in (0, 2) for prediction in (0, 2)]


def extraction_expected(case, rust):
    full = expected(case, rust)
    boundary = max(1, case['count'] // 2)
    prefix = expected(dict(case, count=boundary), rust)
    for field in ('frames', 'checksums', 'skipped', 'total_frames', 'playback'):
        full[field] = prefix[field]
    later = expected(case, False)
    full['extraction'] = dict(at=boundary, final_frame=case['count'], early_unchanged=True,
                              second_extraction_refused=rust, later_frames=-1 if rust else case['count'],
                              later_rows=[] if rust else later['frames'], later_checksums=[] if rust else later['checksums'],
                              later_playback=None if rust else later['playback'])
    return full


def extraction_acceptance(observed):
    names = [f'extract-{players}p-{count}-delay{delay}-prediction{prediction}'
             for players in range(2, 9) for count in (7, 64) for delay in (0, 2) for prediction in (0, 2)]
    for runtime in ('rust', 'godot'):
        result = observed[runtime]
        if type(result) is not dict or set(result) != {'format', 'cases'}:
            raise ValueError(f'extraction.{runtime}: field mismatch')
        compare(result['format'], 1, f'extraction.{runtime}.format')
        cases = result['cases']
        if type(cases) is not list or sorted(case['name'] for case in cases) != sorted(names):
            raise ValueError(f'{runtime}: incomplete continuing extraction inventory')
        for case in cases:
            _, roster, count, delay, prediction = case['name'].split('-')
            specification = dict(name=case['name'], players=int(roster[:-1]), count=int(count),
                                 delay=int(delay[5:]), prediction=int(prediction[10:]), seed=0xffffffff)
            compare(case, extraction_expected(specification, runtime == 'rust'), f'extraction.{runtime}.{case["name"]}')
    return names


def extraction_controls(observed):
    results = []
    for runtime in ('rust', 'godot'):
        for fault in ('continuation', 'snapshot-mutated', 'second-extraction', 'prefix-input', 'saved-state'):
            changed = copy.deepcopy(observed)
            case = next(row for row in changed[runtime]['cases'] if row['name'] == 'extract-5p-64-delay2-prediction2')
            field = {'continuation': 'extraction.final_frame', 'snapshot-mutated': 'extraction.early_unchanged',
                     'second-extraction': 'extraction.second_extraction_refused', 'prefix-input': 'frames[15][2]'}.get(fault)
            if fault == 'continuation':
                case['extraction']['final_frame'] -= 1
            elif fault == 'snapshot-mutated':
                case['extraction']['early_unchanged'] = False
            elif fault == 'second-extraction':
                case['extraction']['second_extraction_refused'] = not case['extraction']['second_extraction_refused']
            elif fault == 'prefix-input':
                case['frames'][15][2] ^= 1
            else:
                index = next(index for index, row in enumerate(case['records']) if row['kind'] == 'save' and row['frame'] == 63)
                case['records'][index]['bytes'] = '00' * 16
                field = f'records[{index}].bytes'
            try:
                extraction_acceptance(changed)
            except ValueError as error:
                if not str(error).startswith(f'extraction.{runtime}.{case["name"]}.{field}:'):
                    raise ValueError(f'{fault}: wrong extraction rejection') from error
                results.append(f'{runtime}-{fault}')
            else:
                raise ValueError(f'{runtime}-{fault}: continuing extraction mutation accepted')
        if runtime == 'godot':
            for fault in ('later-input', 'later-playback'):
                changed = copy.deepcopy(observed)
                case = next(row for row in changed[runtime]['cases'] if row['name'] == 'extract-5p-64-delay2-prediction2')
                if fault == 'later-input':
                    case['extraction']['later_rows'][40][2] ^= 1
                    field = 'extraction.later_rows[40][2]'
                else:
                    records = case['extraction']['later_playback']['records']
                    index = next(index for index, row in enumerate(records) if row['kind'] == 'advance' and row['frame'] == 40)
                    records[index]['bytes'] = '00' * 16
                    field = f'extraction.later_playback.records[{index}].bytes'
                try:
                    extraction_acceptance(changed)
                except ValueError as error:
                    if not str(error).startswith(f'extraction.{runtime}.{case["name"]}.{field}:'):
                        raise ValueError('wrong later recording rejection') from error
                    results.append('godot-' + fault)
                else:
                    raise ValueError('later recording mutation accepted')
    return results


def observe_extraction(binary, command, output, execute):
    cases = extraction_corpus()
    text = json.dumps(cases, indent=2) + '\n'
    fixture = output / 'recording-extraction-cases.json'
    fixture.write_text(text)
    observations = []
    for repeat in (1, 2):
        combined = {}
        for runtime in ('rust', 'godot'):
            invocation = [str(binary), '--recording-extraction'] if runtime == 'rust' else command[:-2] + ['--recording-extraction', str(fixture.resolve())]
            stdout, stderr = execute(invocation, output / f'recording-extraction-{runtime}-{repeat}.log', text if runtime == 'rust' else None)
            if runtime == 'godot':
                lines = [line.removeprefix('FORTRESS_REPLAY_RESULT ') for line in stdout.splitlines() if line.startswith('FORTRESS_REPLAY_RESULT ')]
                if len(lines) != 1 or any(marker in stdout + stderr for marker in ('SCRIPT ERROR:', 'ERROR:', 'Parse Error:')):
                    raise ValueError('invalid continuing extraction completion')
                stdout = lines[0]
            elif stderr.strip():
                raise ValueError('Rust continuing extraction stderr')
            combined[runtime] = json.loads(stdout)
        extraction_acceptance(combined)
        observations.append(combined)
    compare(observations[0], observations[1])
    return dict(workloads=extraction_acceptance(observations[0]), repeat_equal=True,
                cases_sha256=hashlib.sha256(fixture.read_bytes()).hexdigest(),
                negative_controls=extraction_controls(observations[0]), observations=observations[0])

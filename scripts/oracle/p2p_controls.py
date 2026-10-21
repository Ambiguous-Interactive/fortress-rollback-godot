"""Persistent real-process malformed, raw compression and temporal evidence controls."""
from copy import deepcopy
import json
from pathlib import Path
import subprocess
import sys
from contract import checksum, initial_game_state, advance_game_state
from controls import reject
from launch import execute
from run import rust_environment


def temporal_permutation(actual):
    """Swap first two confirmed local input frames; preserve the final full state."""
    mutant = deepcopy(actual)
    # At >=3 frames this application's last pending value and final accumulators
    # depend equally on the first two values, while intermediate prefixes differ.
    first = next(op['bytes'] for op in actual['scenario']['operations'] if op['kind'] == 'step' and op['peer'] == 0)
    second = next(op['bytes'] for op in actual['scenario']['operations'] if op['kind'] == 'step' and op['peer'] == 0 and op['bytes'] != first)
    states = [initial_game_state(actual['scenario']['players'], 2) for _ in range(actual['scenario']['players'])]
    snapshots = [{} for _ in states]
    for record in mutant['records']:
        peer = record['peer']
        for request in record['requests']:
            frame = request['frame']
            if request['kind'] == 'save':
                snapshots[peer][frame] = states[peer]
            elif request['kind'] == 'load':
                states[peer] = snapshots[peer][frame]
            else:
                if frame in (0, 1):
                    slot = request['inputs'][0]
                    if slot['status'] == 'confirmed':
                        slot['bytes'] = second if frame == 0 else first
                incoming = [int.from_bytes(bytes.fromhex(slot['bytes']), 'little') for slot in request['inputs']]
                states[peer] = advance_game_state(states[peer], incoming, 2)
            request['state_bytes'] = states[peer].hex()
            request['checksum'] = checksum(states[peer])
        record['state'] = states[peer].hex()
    for peer in range(len(states)):
        original = next(record['state'] for record in reversed(actual['records']) if record['peer'] == peer)
        changed = next(record['state'] for record in reversed(mutant['records']) if record['peer'] == peer)
        if original != changed:
            raise ValueError('temporal control failed to preserve final state')
    return mutant



def profile_audit_controls(binary, directory):
    """Low windows require explicit source-only mode and never enter comparison."""
    from p2p_contract import REVISION
    from contract import fields, integer
    controls = []
    for window in (0, 1):
        scenario = {'format': 1, 'players': 2, 'input_delay': 0, 'max_prediction': window,
                    'operations': [{'kind': 'poll', 'peer': 0, 'now_us': 0}]}
        outputs = []
        for repeat in (1, 2):
            stdout, stderr = execute([str(binary), '--profile-audit'], directory / f'control-profile-audit-{window}-{repeat}.log', json.dumps(scenario))
            value = json.loads(stdout)
            fields(value, 'format complete upstream_revision scenario records packets', 'profile audit trace')
            integer(value['format'], 1, 1, 'profile audit format')
            if (stderr.strip() or value['complete'] is not True or value['upstream_revision'] != REVISION
                    or value['scenario'] != scenario or type(value['records']) is not list or len(value['records']) != 1 or value['packets'] != []):
                raise ValueError('profile audit completion')
            record = value['records'][0]
            fields(record, 'index peer frame_before frame_after confirmed_frame error requests events outgoing state', 'profile audit record')
            for key in ('index', 'peer', 'frame_before', 'frame_after'):
                integer(record[key], 0, 0, 'profile audit ' + key)
            integer(record['confirmed_frame'], -1, -1, 'profile audit confirmed frame')
            if (record['error'] is not None or record['requests'] != [] or record['events'] != [] or record['outgoing'] != []
                    or record['state'] != initial_game_state(2, 2).hex()):
                raise ValueError('profile audit observed poll')
            outputs.append(value)
        if outputs[0] != outputs[1]:
            raise ValueError('profile audit repeat divergence')
        controls.append('explicit_source_profile_audit_' + str(window))
    return controls

def wire_mutant(observer, field):
    """Mutate an actual encoded outgoing packet in an isolated observer copy."""
    if field == 'players':
        anchor = '\t\tvar message: T.Message = result.message\n'
        mutation = """		if message.kind == T.Kind.INPUT:
			message.players = PackedByteArray([(player + 1) % peers.size()])
			var corrupted: T.Result = Codec.encode(message, limits)
			if corrupted.code != T.Code.OK:
				_fail("wire control encode")
				return false
			packet.bytes = corrupted.bytes
			var observed: T.Result = Codec.decode(packet.bytes, limits)
			if observed.code != T.Code.OK:
				_fail("wire control decode")
				return false
			message = observed.message
			print("FORTRESS_P2P_WIRE_MUTATION " + JSON.stringify({"field": "players", "observed": Array(message.players)}))
"""
        replacement = anchor + mutation
    elif field in {'session_id', 'sender_id', 'connection_id'}:
        anchor = '\t\tvar result: T.Result = Codec.decode(packet.bytes, limits)\n'
        value = '_token(1, 0)' if field == 'session_id' else '_id((player + 1) % peers.size())'
        mutation = """		var unbound: T.Limits = T.Limits.new()
		unbound.player_count = limits.player_count
		unbound.input_width = limits.input_width
		var original: T.Result = Codec.decode(packet.bytes, unbound)
		if original.code != T.Code.OK:
			_fail("wire control original decode")
			return false
		original.message.FIELD = VALUE
		var corrupted: T.Result = Codec.encode(original.message, unbound)
		if corrupted.code != T.Code.OK:
			_fail("wire control encode")
			return false
		packet.bytes = corrupted.bytes
		var observed: T.Result = Codec.decode(packet.bytes, unbound)
		if observed.code != T.Code.OK:
			_fail("wire control decode")
			return false
		print("FORTRESS_P2P_WIRE_MUTATION " + JSON.stringify({"field": "FIELD", "observed": observed.message.FIELD.hex_encode()}))
""".replace('FIELD', field).replace('VALUE', value)
        replacement = mutation + anchor
    else:
        raise ValueError('unknown wire mutation')
    if observer.count(anchor) != 1:
        raise ValueError('wire control observer boundary changed')
    return observer.replace(anchor, replacement, 1)


def wire_controls(binary, engine, directory):
    from p2p_contract import validate, compare
    from p2p_launch import parse_godot
    root = Path(__file__).resolve().parents[2]
    scenario = {'format': 1, 'players': 2, 'input_delay': 0, 'max_prediction': 4,
                'operations': [{'kind': 'step', 'peer': 0, 'now_us': 0, 'bytes': '11000000'}]}
    path = directory / 'control-wire-scenario.json'; path.write_text(json.dumps(scenario) + '\n')
    stdout, stderr = execute([str(binary)], directory / 'control-wire-source.log', json.dumps(scenario))
    if stderr.strip():
        raise ValueError('wire control source process output')
    expected = json.loads(stdout); validate(expected, scenario, True)
    (directory / 'control-wire-source.json').write_text(json.dumps(expected, indent=2) + '\n')
    observer = (root / 'tests/oracle/p2p_trace.gd').read_text(encoding='utf-8')
    controls = []
    for field in ('players', 'session_id', 'sender_id', 'connection_id'):
        script = directory / ('control-wire-' + field + '.gd'); script.write_text(wire_mutant(observer, field), encoding='utf-8')
        command = [str(engine.resolve()), '--headless', '--path', str(root), '--script', str(script.resolve()), '--', '--scenario', str(path.resolve())]
        log = directory / ('control-wire-' + field + '.log')
        if field == 'players':
            stdout, stderr = execute(command, log)
            actual = parse_godot(stdout, stderr)
            try:
                compare(actual, expected, scenario)
            except ValueError as error:
                if str(error) != 'sender slot: invalid integer':
                    raise ValueError('wire player control wrong boundary') from error
            else:
                raise ValueError('wrong encoded player slot escaped observation')
        else:
            rejected = reject(command, log, rust_environment(), expected_prefix='FORTRESS_P2P_ERROR outgoing codec', expected_exit=2)
            stdout, stderr = rejected.stdout, rejected.stderr
            if 'ERROR:' in stdout + stderr:
                raise ValueError('wire identity control caused engine error')
        prefix = 'FORTRESS_P2P_WIRE_MUTATION '
        proof = [json.loads(line[len(prefix):]) for line in stdout.splitlines() if line.startswith(prefix)]
        wanted = [1] if field == 'players' else ('02000000000000000100000000000000' if field == 'session_id' else '0200000000000000')
        if proof != [{'field': field, 'observed': wanted}]:
            raise ValueError('wire control did not observe encoded mutation')
        controls.append('actual_encoded_wire_' + field + '_rejected')
    return controls


def process_controls(binary, engine, scenario, expected, actual, directory):
    environment = rust_environment()
    mutants = {'empty': {}, 'empty_operations': dict(scenario, operations=[]), 'unknown': dict(scenario, extra=True)}
    value = deepcopy(scenario); value['operations'][0]['now_us'] = True; mutants['bool_time'] = value
    value = deepcopy(scenario); value['operations'][0]['bytes'] = ''; mutants['empty_input'] = value
    for field in ('format', 'players', 'input_delay', 'max_prediction'):
        for alias_name, alias in [('float', float(scenario[field])), ('null', None)]:
            value = deepcopy(scenario); value[field] = alias; mutants[alias_name + '_' + field] = value
    for field in ('peer', 'now_us'):
        for alias_name, alias in [('float', float(scenario['operations'][0][field])), ('null', None)]:
            value = deepcopy(scenario); value['operations'][0][field] = alias; mutants[alias_name + '_' + field] = value
    # Delay changes: before the first step, after another peer's operation, in the bound band, and aliased.
    if scenario['operations'][0]['kind'] == 'step':
        peer = scenario['operations'][0]['peer']
        for name, op, index in [('delay_before_step', {'kind': 'delay', 'peer': peer, 'delay': 1}, 0),
                                ('delay_bound_band', {'kind': 'delay', 'peer': peer, 'delay': 100}, 1),
                                ('delay_float', {'kind': 'delay', 'peer': peer, 'delay': 1.0}, 1),
                                ('delay_clock_field', {'kind': 'delay', 'peer': peer, 'delay': 1, 'now_us': 0}, 1),
                                ('delay_after_other_peer', {'kind': 'delay', 'peer': peer, 'delay': 1}, 2)]:
            value = deepcopy(scenario); value['operations'].insert(index, op); mutants[name] = value
    mutants['exponent_format'] = json.dumps(scenario).replace('"format": 1,', '"format": 1e0,', 1)
    for window in (0, 1):
        mutants['low_prediction_' + str(window)] = dict(scenario, max_prediction=window)
    controls = []
    for name, value in mutants.items():
        payload = value if type(value) is str else json.dumps(value)
        reject([str(binary)], directory / f'control-rust-{name}.log', environment, payload, 'p2p oracle:', 2)
        path = directory / f'control-{name}.json'; path.write_text(payload + '\n')
        reject([str(engine.resolve()), '--headless', '--path', str(Path(__file__).resolve().parents[2]), '--script',
            'res://tests/oracle/p2p_trace.gd', '--', '--scenario', str(path.resolve())], directory / f'control-godot-{name}.log',
            environment, expected_prefix='FORTRESS_P2P_ERROR invalid scenario', expected_exit=2)
        controls.append('malformed_' + name)
    controls.extend(profile_audit_controls(binary, directory))
    controls.extend(wire_controls(binary, engine, directory))
    # Numeric-looking text and escaped quotes remain strings, never numeric tokens.
    quoted = '{"format":1,"players":2,"input_delay":0,"max_prediction":4,"operations":[{"kind":"p\\u006fll","peer":0,"now_us":0}]}'
    path = directory / 'control-quoted-integers.json'; path.write_text(quoted + '\n')
    stdout, stderr = execute([str(engine.resolve()), '--headless', '--path', str(Path(__file__).resolve().parents[2]), '--script',
        'res://tests/oracle/p2p_trace.gd', '--', '--scenario', str(path.resolve())], directory / 'control-godot-quoted.log')
    from p2p_launch import parse_godot
    from p2p_contract import validate
    validate(parse_godot(stdout, stderr), json.loads(quoted))
    controls.append('quoted_escape_preserves_integer_schema')
    stdout, stderr = execute([str(engine.resolve()), '--headless', '--path', str(Path(__file__).resolve().parents[2]), '--script',
        'res://tests/oracle/p2p_game_controls.gd'], directory / 'control-godot-game-inputs.log')
    prefix = 'FORTRESS_P2P_GAME_CONTROL '
    rows = [line[len(prefix):] for line in stdout.splitlines() if line.startswith(prefix)]
    if stderr.strip() or len(rows) != 1:
        raise ValueError('game input control process output')
    result = json.loads(rows[0])
    if (type(result) is not dict or set(result) != {'complete', 'passed', 'checks', 'failures'}
            or result['complete'] is not True or result['passed'] is not True
            or type(result['checks']) is not int or result['checks'] != 28 or result['failures'] != []):
        raise ValueError('game input control completion')
    controls.append('game_rejects_invalid_status_and_view_codes_without_mutation')
    raw = deepcopy(expected)
    packet = next(p for p in raw['packets'] if p['semantic']['kind'] == 'input')
    packet['raw']['body']['Input']['bytes'][1] ^= 1
    reject([str(binary), '--validate-trace'], directory / 'control-compressed.log', environment,
        json.dumps(raw), 'raw compressed semantic mismatch', 2)
    controls.append('actual_source_decoder_raw_compression')
    original = directory / 'control-original-scenario.json'; original.write_text(json.dumps(scenario) + '\n')
    expected_path = directory / 'control-original-source.json'; expected_path.write_text(json.dumps(expected) + '\n')
    validator = [sys.executable, str(Path(__file__).with_name('p2p_validate.py')), '--scenario', str(original), '--expected', str(expected_path)]
    mutant = temporal_permutation(actual)
    path = directory / 'control-temporal.json'; path.write_text(json.dumps(mutant, indent=2) + '\n')
    reject(validator, directory / 'control-temporal.log', environment, json.dumps(mutant),
        'operation 0: submitted confirmed prefix frame 0 slot 0', 2)
    controls.append('temporal_permutation_preserves_final_states')
    for name, value, diagnostic in [
        ('partial', dict(actual, records=actual['records'][:-1]), 'record inventory'),
        ('event', dict(actual, records=[dict(actual['records'][0], events=['invented']), *actual['records'][1:]]), 'unmodeled event'),
        ('confirmed_alias', dict(actual, records=[dict(actual['records'][0], confirmed_frame=False), *actual['records'][1:]]), 'invalid integer'),
        ('confirmed_value', dict(actual, records=[dict(actual['records'][0], confirmed_frame=42), *actual['records'][1:]]), 'operation 0: confirmed_frame mismatch')]:
        reject(validator, directory / f'control-process-{name}.log', environment, json.dumps(value), diagnostic, 2)
        controls.append('process_' + name)
    # A plausible complete stream followed by nonzero exit is still failure.
    try:
        execute([sys.executable, '-c', 'import sys; print(sys.stdin.read()); sys.exit(7)'],
            directory / 'control-plausible-crash.log', json.dumps(actual))
    except ValueError as error:
        if 'process failed (7)' not in str(error):
            raise ValueError('crash control wrong boundary') from error
    else:
        raise ValueError('plausible crash accepted')
    controls.append('plausible_complete_nonzero_exit')
    return controls

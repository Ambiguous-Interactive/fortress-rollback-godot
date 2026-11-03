"""Actual encoded-width corruption controls for source-bound replay acceptance."""
import copy
import json


def controls(binary, engine, output, execute):
    from replay_launch import ROOT, compare, encoded, expected, state_bytes, advance, width_case
    case = width_case(2, 2, 'sparse')
    bundle = dict(name=case['name'], seed=case['seed'], validate=True,
                  replay=encoded(case).hex(), replay_v4=encoded(case, 4).hex(), replay_v6=encoded(case, 6).hex())
    command = [str(engine), '--headless', '--path', str(ROOT), '--script', 'res://tests/oracle/replay_session_trace.gd']

    def observe(value, name):
        fixture = output / f'width-{name}.json'
        fixture.write_text(json.dumps([value]) + '\n')
        stdout, stderr = execute(command + ['--', '--bundle', str(fixture.resolve())], output / f'width-{name}.log')
        lines = [line.removeprefix('FORTRESS_REPLAY_RESULT ') for line in stdout.splitlines() if line.startswith('FORTRESS_REPLAY_RESULT ')]
        if len(lines) != 1 or any(marker in stdout + stderr for marker in ('SCRIPT ERROR:', 'ERROR:', 'Parse Error:')):
            raise ValueError('width control: missing completion or engine error')
        return json.loads(lines[0])

    wanted = dict(format=1, cases=[expected(case, False, expert, version) for version in (5, 4, 6) for expert in (False, True)])
    compare(observe(bundle, 'green'), wanted, 'width.green')
    changed = copy.deepcopy(bundle)
    for version, field in ((5, 'replay'), (4, 'replay_v4'), (6, 'replay_v6')):
        data = bytearray.fromhex(bundle[field])
        cursor = 23 + 2
        for _ in range(5):
            cursor += 1 + data[cursor]
        for frame in range(32):
            cursor += 4 + (2 if version >= 5 else 0) + 1 + (16 if frame % 2 == 0 else 0) + 16
        # Alter the high byte only. Narrowing every sample to u8 would silently miss this damage.
        data[cursor + 1] ^= 0x80
        changed[field] = data.hex()
    state = (0, case['seed'], case['seed'], 0)
    for row in case['frames'][:32]:
        state = advance(state, row)
    altered = copy.deepcopy(wanted)
    for observation in altered['cases']:
        observation.update(code=18, failure_frame=32, failure_comparison='input_digest', current_frame=32,
                           complete=False, bytes=state_bytes(state).hex())
        observation['records'] = [record for record in observation['records'] if record['frame'] < 32]
    compare(observe(changed, 'high-byte-corruption'), altered, 'width.high-byte-corruption')
    results = ['godot-width-high-byte-corruption-v4-v5-v6-callback-expert']
    for name, altered_case in [('invalid-width', dict(case, width=3)),
                               ('out-of-width-input', dict(case, frames=[[65536, 1]] + case['frames'][1:]))]:
        log = output / f'width-rust-{name}.log'
        try:
            execute([str(binary)], log, json.dumps([altered_case]))
        except ValueError:
            text = log.read_text()
            if 'invalid replay dimensions' not in text or '"format"' in text:
                raise ValueError('width source rejected at wrong boundary')
        else:
            raise ValueError('width source accepted invalid dimensions')
        results.append('rust-width-' + name)
    return results

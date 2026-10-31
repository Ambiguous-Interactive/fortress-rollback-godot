"""Manual request execution must preserve the callback driver's complete recording history."""
import copy
import json

from replay_launch import compare


def validate(actual, wanted, terminal):
    expected_calls = []
    for peer in wanted['peers']:
        calls = [dict(operation='advance', before=row['before'], after=row['after'],
                      code=3 if row['before'] == row['after'] else 0) for row in peer['services']]
        calls.append(dict(operation='recover', before=257, after=257, code=0))
        if terminal:
            calls.append(dict(operation='capture', before=257, after=257, code=0))
        expected_calls.append(calls)
    compare(actual.get('expert_calls'), expected_calls, 'api_parity.expert_calls')
    actual = {key: value for key, value in actual.items() if key != 'expert_calls'}
    compare(actual, wanted, 'api_parity.history')


def observe(engine, root, output, execute, wanted, mode, terminal=False):
    """Use independent original-history expectations supplied by the asymmetric/pressure models."""
    observations = []
    for repeat in (1, 2):
        stdout, stderr = execute([str(engine), '--headless', '--path', str(root), '--script',
                                  'res://tests/oracle/replay_remote_trace.gd', '--', mode, '--expert'],
                                 output / f'{mode[2:]}-expert-{repeat}.log')
        lines = [line.removeprefix('FORTRESS_REPLAY_RESULT ') for line in stdout.splitlines()
                 if line.startswith('FORTRESS_REPLAY_RESULT ')]
        if len(lines) != 1 or any(marker in stdout + stderr for marker in ('SCRIPT ERROR:', 'ERROR:', 'Parse Error:')):
            raise ValueError('invalid manual recording completion')
        actual = json.loads(lines[0])
        validate(actual, wanted, terminal)
        observations.append(actual)
    compare(observations[0], observations[1], 'api_parity.repeat')
    rejected = []
    for fault in ('missing-call', 'result-code', 'recovery-advance', 'history'):
        changed = copy.deepcopy(observations[0])
        if fault == 'missing-call':
            changed['expert_calls'][0].pop()
            field = 'expert_calls[0]'
        elif fault == 'result-code':
            changed['expert_calls'][1][4]['code'] = 999
            field = 'expert_calls[1][4].code'
        elif fault == 'recovery-advance':
            changed['expert_calls'][0][-2 if terminal else -1]['after'] += 1
            field = f'expert_calls[0][{len(changed["expert_calls"][0]) - (2 if terminal else 1)}].after'
        else:
            changed['peers'][1]['frames'][129][0] ^= 1
            field = 'history.peers[1].frames[129][0]'
        try:
            validate(changed, wanted, terminal)
        except ValueError as error:
            prefix = 'api_parity.' + field
            if not str(error).startswith(prefix + ':'):
                raise ValueError(f'{fault}: wrong API parity rejection: {error}') from error
        else:
            raise ValueError(f'{fault}: API parity mutation accepted')
        rejected.append(fault)
    return dict(repeat_equal=True, observations=observations[0], negative_controls=rejected)

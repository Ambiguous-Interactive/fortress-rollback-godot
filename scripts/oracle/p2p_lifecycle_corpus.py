"""Lifecycle schedules are built from actual public source packet inventories."""
from p2p_contract import validate_scenario


def corpus(binary, observe, selected=None):
    names = ('control_boundaries', 'quality_echo_resume', 'quality_rtt_advantage', 'disconnect_boundary', 'checksums_match', 'checksums_repair', 'checksums_diverge', 'pacing_skew')
    return {name: build(binary, observe, name) for name in names if selected is None or selected == name}


def build(binary, observe, name):
    settings = {'quality_us': 200000, 'keepalive_us': 100000, 'notify_us': 500000,
                'timeout_us': 5000000, 'checksum_interval': 0, 'divergent_peer': -1}
    if name.startswith('checksums'):
        settings.update(checksum_interval=2, quality_us=100000000, keepalive_us=100000000)
    if name == 'checksums_diverge':
        settings['divergent_peer'] = 1
    if name == 'pacing_skew':
        settings.update(notify_us=5000000, timeout_us=10000000)
    scenario = {'format': 1, 'players': 2, 'input_delay': 0, 'max_prediction': 8, 'lifecycle': settings, 'operations': []}
    latest = None; now = 0; delivered = set()
    def append(kind, at=None, refresh=True, **kwargs):
        nonlocal latest, now
        now = now + 1 if at is None else at
        scenario['operations'].append(dict(kind=kind, now_us=now, **kwargs))
        if refresh:
            latest = observe(binary, scenario)
    def step(peer, at=None):
        frame = next((r['frame_after'] for r in reversed(latest['records']) if r['peer'] == peer), 0) if latest else 0
        append('step', peer=peer, bytes=((frame + 1) * (peer + 1) * 17).to_bytes(4, 'little').hex(), at=at)
    def flush(reverse=False):
        nonlocal latest
        for _ in range(20):
            pending = [p for p in latest['packets'] if p['id'] not in delivered]
            if not pending:
                return
            if reverse:
                pending.reverse()
            for packet in pending:
                delivered.add(packet['id']); append('deliver', packet=packet['id'], refresh=False)
            latest = observe(binary, scenario)
        raise ValueError('lifecycle flush not bounded')
    if name == 'control_boundaries':
        for time in (100000, 100001, 200000, 200001, 500000, 500001, 1000000):
            append('poll', peer=0, at=time)
    elif name == 'quality_echo_resume':
        append('poll', peer=0, at=200001)
        report = latest['packets'][0]['id']
        append('poll', peer=1, at=500000)
        append('poll', peer=1, at=500001)
        append('deliver', packet=report, at=1000000)
        pong = next(p['id'] for p in latest['packets'] if p['semantic']['kind'] == 'quality_reply' and p['from'] == 1)
        append('deliver', packet=pong, at=1100000)
        flush()
        for peer in range(2):
            append('poll', peer=peer)
    elif name == 'quality_rtt_advantage':
        step(0); step(1); flush()
        append('poll', peer=0, at=200001)
        report = next(p['id'] for p in latest['packets'] if p['semantic']['kind'] == 'quality_report' and p['from'] == 0)
        delivered.add(report); append('deliver', packet=report, at=250001)
        pong = next(p['id'] for p in latest['packets'] if p['semantic']['kind'] == 'quality_reply' and p['from'] == 1)
        delivered.add(pong); append('deliver', packet=pong, at=300001)
        append('poll', peer=0, at=1000000)
        step(0); step(1); flush()
        for peer in range(2):
            append('poll', peer=peer)
    elif name == 'disconnect_boundary':
        settings.update(quality_us=100000000, keepalive_us=100000000)
        for time in (500000, 500001, 5000000, 5000001):
            append('poll', peer=0, at=time)
    else:
        for frame in range(48 if name == 'pacing_skew' else 14):
            if name == 'pacing_skew':
                step(0, at=frame * 50000 + 1)
                if frame % 3 == 0:
                    step(1)
                flush()
            else:
                step(0)
                if name == 'checksums_diverge' and any(r['events'] for r in latest['records']):
                    break
                step(1)
                if name == 'checksums_diverge' and any(r['events'] for r in latest['records']):
                    break
                if name == 'checksums_repair' and frame % 3 == 0:
                    continue
                flush(reverse=name == 'checksums_repair')
        if name != 'checksums_diverge':
            flush()
            for peer in range(2):
                step(peer)
                flush()
    validate_scenario(scenario)
    return scenario

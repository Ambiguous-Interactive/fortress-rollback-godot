"""Strict optional P4 observations retain actual public source metrics and controls."""
from contract import fields, integer, hex_bytes


def settings(value, players):
    fields(value, 'quality_us keepalive_us notify_us timeout_us checksum_interval divergent_peer', 'lifecycle')
    for key in ('quality_us', 'keepalive_us'):
        integer(value[key], 1000, 100000000, key)
    integer(value['notify_us'], 1, 9999999, 'notify')
    integer(value['timeout_us'], value['notify_us'] + 1, 10000000, 'timeout')
    integer(value['checksum_interval'], 0, 60, 'checksum interval')
    integer(value['divergent_peer'], -1, players - 1, 'divergent peer')


def control(value, source):
    body = value['semantic']; kind = body['kind']
    names = {'quality_report': 'kind frame_advantage ping', 'quality_reply': 'kind pong',
             'keep_alive': 'kind', 'goodbye': 'kind reason', 'checksum_report': 'kind frame checksum'}
    fields(body, names[kind], 'control body')
    if kind == 'goodbye':
        integer(body['reason'], 255, 255, 'terminal goodbye reason')
        if source:
            raise ValueError('source goodbye outside profile')
    elif kind == 'quality_report':
        integer(body['frame_advantage'], -32768, 32767, 'frame advantage')
        hex_bytes(body['ping'], 16, 'ping')
    elif kind == 'quality_reply':
        hex_bytes(body['pong'], 16, 'pong')
    elif kind == 'checksum_report':
        integer(body['frame'], 0, 10000, 'checksum frame')
        hex_bytes(body['checksum'], 16, 'network checksum')
    if source:
        raw = value['raw']; raw_body = raw['body']
        if kind == 'keep_alive':
            if raw_body != 'KeepAlive':
                raise ValueError('raw keepalive')
            return
        variant = {'quality_report': 'QualityReport', 'quality_reply': 'QualityReply', 'checksum_report': 'ChecksumReport'}[kind]
        fields(raw_body, variant, 'raw control variant'); raw_body = raw_body[variant]
        fields(raw_body, names[kind].replace('kind ', ''), 'raw control')
        for key, actual in raw_body.items():
            if key in ('ping', 'pong', 'checksum'):
                integer(actual, 0, (1 << 128) - 1, 'raw wide integer')
                if f'{actual:032x}' != body[key]:
                    raise ValueError('raw wide semantic')
            else:
                low, high = (-32768, 32767) if key == 'frame_advantage' else (0, 10000)
                integer(actual, low, high, 'raw ' + key)
                if actual != body[key]:
                    raise ValueError('raw scalar semantic')


def events(value, players):
    if type(value) is not list:
        raise ValueError('lifecycle event inventory')
    for event in value:
        if type(event) is not dict or type(event.get('kind')) is not str:
            raise ValueError('lifecycle event')
        kind = event['kind']
        fields(event, {'network_interrupted': 'kind peer disconnect_timeout', 'network_resumed': 'kind peer',
                       'disconnected': 'kind peer' + (' reason' if 'reason' in event else ''), 'wait_recommendation': 'kind skip_frames',
                       'desync_detected': 'kind frame local_checksum remote_checksum peer'}.get(kind, ''), 'lifecycle event')
        if kind == 'disconnected' and 'reason' in event and event['reason'] != 'timeout':
            raise ValueError('disconnect reason')
        if kind == 'wait_recommendation':
            integer(event['skip_frames'], 1, 10000, 'wait frames')
        else:
            integer(event['peer'], 0, players - 1, 'event peer')
        if kind == 'network_interrupted':
            integer(event['disconnect_timeout'], 0, 10000, 'remaining timeout')
        if kind == 'desync_detected':
            integer(event['frame'], 0, 10000, 'desync frame')
            for key in ('local_checksum', 'remote_checksum'):
                hex_bytes(event[key], 16, key)


def metrics(value, peer, players):
    fields(value, 'frames_ahead peers', 'metrics')
    integer(value['frames_ahead'], -(1 << 31), (1 << 31) - 1, 'frames ahead')
    if type(value['peers']) is not list or len(value['peers']) != players - 1:
        raise ValueError('metric peers')
    for remote, item in zip((r for r in range(players) if r != peer), value['peers']):
        if type(item) is not dict:
            raise ValueError('peer metric')
        available = item.get('error') is None
        fields(item, 'peer error ping local_frames_behind remote_frames_behind' if available else 'peer error', 'peer metric')
        integer(item['peer'], remote, remote, 'metric peer')
        if available:
            integer(item['ping'], 0, 10000, 'RTT')
            for key in ('local_frames_behind', 'remote_frames_behind'):
                integer(item[key], -(1 << 31), (1 << 31) - 1, key)
        elif item['error'] != 'NotSynchronized':
            raise ValueError('unmodeled source stats error')


def terminal_notifications(actual, scenario):
    """Validate every excluded local close against the final real desync policy."""
    for index, record in enumerate(actual['records']):
        extensions = [e for e in record['extension_events'] if e['kind'] == 'disconnected']
        goodbyes = [actual['packets'][i] for i in record['outgoing']
                    if actual['packets'][i]['semantic']['kind'] == 'goodbye']
        desync = any(e['kind'] == 'desync_detected' for e in record['events'])
        remotes = [peer for peer in range(scenario['players']) if peer != record['peer']]
        if index == len(actual['records']) - 1 and desync:
            required = [{'kind': 'disconnected', 'peer': peer, 'reason': 255} for peer in remotes]
            if extensions != required:
                raise ValueError(f'operation {index}: terminal extension membership')
            if [p['to'] for p in goodbyes] != [peer for peer in remotes for _ in range(3)]:
                raise ValueError(f'operation {index}: terminal goodbye membership/count')
            if any(p['from'] != record['peer'] or p['semantic']['reason'] != 255 for p in goodbyes):
                raise ValueError(f'operation {index}: terminal goodbye sender/reason')
        elif extensions or goodbyes:
            raise ValueError(f'operation {index}: terminal notifications outside desync policy')


def terminal_projection(actual, expected, scenario):
    """One final first terminal trigger: source continues; Godot freezes membership."""
    left = actual['records']; right = expected['records']
    terminals = [(index, event) for index, record in enumerate(right) for event in record['events']
                 if event['kind'] in {'disconnected', 'desync_detected'}]
    actual_terminals = [(index, event) for index, record in enumerate(left) for event in record['events']
                        if event['kind'] in {'disconnected', 'desync_detected'}]
    if not terminals and not actual_terminals:
        return
    if len(terminals) != 1 or len(actual_terminals) != 1 or terminals[0][0] != len(right) - 1 or actual_terminals[0][0] != len(left) - 1:
        raise ValueError('terminal projection requires first final trigger')
    event = terminals[0][1]; observed = dict(actual_terminals[0][1])
    if observed.get('kind') == 'disconnected':
        if observed.pop('reason', None) != 'timeout':
            raise ValueError('terminal timeout reason')
    if observed != event:
        raise ValueError(f'operation {len(left) - 1}: terminal trigger mismatch')
    a = left[-1]; e = right[-1]
    for key in ('peer', 'frame_before', 'pre_state', 'pre_confirmed'):
        if a[key] != e[key]:
            raise ValueError('terminal pre-boundary mismatch')
    if a['frame_after'] != a['frame_before'] or a['state'] != a['pre_state'] or a['requests'] or a['confirmed_frame'] != a['pre_confirmed']:
        raise ValueError(f'operation {len(left) - 1}: Godot terminal boundary not frozen')
    if event['kind'] == 'desync_detected':
        if scenario['operations'][-1]['kind'] != 'step' or a['error'] != 'DESYNC' or e['error'] is not None:
            raise ValueError('terminal desync policy boundary')
        # Source returns callbacks and submits input after reporting the mismatch.
        # They remain fully validated and retained in the raw trace; only this final
        # continuation is outside fixed-membership Godot behavior.
        e['requests'] = []; e['frame_after'] = e['frame_before']; e['state'] = e['pre_state']
        e['confirmed_frame'] = e['pre_confirmed']; e['error'] = 'DESYNC'
        removed = []
        for packet_id in e['outgoing']:
            packet = expected['packets'][packet_id]
            if packet['semantic']['kind'] == 'input':
                removed.append(packet_id)
        if removed:
            if removed != list(range(removed[0], len(expected['packets']))):
                raise ValueError('terminal input continuation not suffix')
            if any(p['from'] != e['peer'] for p in expected['packets'][removed[0]:]):
                raise ValueError('terminal continuation sender')
            expected['packets'] = expected['packets'][:removed[0]]
            e['outgoing'] = [p for p in e['outgoing'] if p not in removed]
    else:
        actual_terminals[0][1].pop('reason')
    removed = [packet_id for packet_id in a['outgoing'] if actual['packets'][packet_id]['semantic']['kind'] == 'goodbye']
    if removed:
        if removed != list(range(removed[0], len(actual['packets']))):
            raise ValueError('terminal goodbye not suffix')
        if any(p['from'] != a['peer'] or p['semantic']['reason'] != 255 for p in actual['packets'][removed[0]:]):
            raise ValueError('terminal goodbye sender/reason')
        actual['packets'] = actual['packets'][:removed[0]]
        a['outgoing'] = [p for p in a['outgoing'] if p not in removed]
    # Source tears down its remote endpoint after timeout and can advance pacing
    # during its post-desync continuation. Those postterminal gauges are retained
    # raw but do not describe the Godot fixed-membership terminal policy.
    a.pop('metrics'); e.pop('metrics')


CORPUS_REQUIREMENTS = {
    'control_boundaries': ('quality_report keep_alive network_interrupted stats_transition', 'quality_advantage quality_ping notify_payload'),
    'quality_echo_resume': ('quality_report quality_reply network_interrupted network_resumed measured_rtt stats_transition',
                            'quality_advantage quality_ping quality_pong notify_payload resume_event measured_rtt'),
    'quality_rtt_advantage': ('quality_report quality_reply measured_rtt nonzero_advantage stats_transition',
                              'quality_advantage quality_ping quality_pong measured_rtt'),
    'disconnect_boundary': ('network_interrupted disconnected stats_transition',
                            'notify_payload terminal_peer terminal_earlier terminal_unfrozen invented_self_extension'),
    'checksums_match': ('checksum_report nonzero_checksum', 'checksum_payload'),
    'checksums_repair': ('checksum_report nonzero_checksum repair_load', 'checksum_payload'),
    'checksums_diverge': ('checksum_report nonzero_checksum desync_detected',
                          'checksum_payload terminal_peer terminal_earlier terminal_unfrozen invented_self_extension '
                          'desync_frame desync_local_checksum desync_remote_checksum duplicate_remote_extension duplicate_goodbye'),
    'pacing_skew': ('quality_report quality_reply wait_recommendation nonzero_advantage stats_transition',
                    'quality_advantage quality_ping quality_pong wait_payload')}


def corpus_evidence(name, source, controls):
    """Named acceptance cases must exercise their declared real-source boundaries."""
    if name not in CORPUS_REQUIREMENTS:
        return {}
    from collections import Counter
    counts = Counter(p['semantic']['kind'] for p in source['packets'])
    counts.update(e['kind'] for r in source['records'] for e in r['events'])
    gauges = [m for r in source['records'] for m in r['metrics']['peers']]
    available = [m for m in gauges if m['error'] is None]
    counts['measured_rtt'] = sum(m['ping'] > 0 for m in available)
    counts['nonzero_advantage'] = sum(m['local_frames_behind'] != 0 or m['remote_frames_behind'] != 0 for m in available)
    seen_unavailable = set(); transitions = set()
    for record in source['records']:
        for metric in record['metrics']['peers']:
            identity = (record['peer'], metric['peer'])
            if metric['error'] == 'NotSynchronized':
                seen_unavailable.add(identity)
            elif identity in seen_unavailable:
                transitions.add(identity)
    counts['stats_transition'] = len(transitions)
    counts['nonzero_checksum'] = sum(p['semantic']['checksum'] != '00' * 16 for p in source['packets']
                                     if p['semantic']['kind'] == 'checksum_report')
    counts['repair_load'] = sum(q['kind'] == 'load' for r in source['records'] for q in r['requests'])
    required, mutations = CORPUS_REQUIREMENTS[name]
    for observation in required.split():
        if counts[observation] <= 0:
            raise ValueError(f'corpus {name}: missing required source observation {observation}')
    for mutation in mutations.split():
        if mutation not in controls:
            raise ValueError(f'corpus {name}: missing required control {mutation}')
    if name in {'checksums_match', 'checksums_repair'} and counts['desync_detected']:
        raise ValueError(f'corpus {name}: unexpected desync')
    return {'required_observations': {key: counts[key] for key in required.split()}, 'required_controls': mutations.split()}

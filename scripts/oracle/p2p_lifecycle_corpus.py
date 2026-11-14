"""Lifecycle schedules are built from actual public source packet inventories."""
from p2p_contract import validate_scenario


def corpus(binary, observe, selected=None):
    names = ('control_boundaries', 'quality_echo_resume', 'quality_rtt_advantage', 'disconnect_boundary',
             'partition_one_way', 'partition_heal', 'partition_heal_mesh', 'partition_fairness', 'checksums_match',
             'checksums_repair', 'checksums_diverge', 'pacing_skew')
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
    if name == 'partition_one_way':
        # Starvation latches interruption at notify and the terminal at timeout;
        # both bounds stay inside the schedule's polls.
        settings.update(timeout_us=2500000)
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
    def cut(packet):
        return {packet['from'], packet['to']} == {1, 2}
    def flush_around(dead):
        nonlocal latest
        for _ in range(40):
            pending = [p for p in latest['packets'] if p['id'] not in delivered and not dead(p)]
            if not pending:
                return
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
    elif name == 'partition_one_way':
        # A short confirmed prefix, then one-way loss: peer 1 stops receiving
        # everything from peer 0 while peer 0 keeps receiving peer 1. Peer 1
        # predicts through the starvation, latches the disconnect timeout and
        # ends the schedule at its terminal; peer 0 never observes a departure.
        for _ in range(3):
            step(0); step(1); flush()
        for frame in range(12):
            now = 500000 + frame * 150000
            step(0, at=now); step(1, at=now + 1)
            pending = [p['id'] for p in latest['packets'] if p['id'] not in delivered and p['from'] == 1]
            for packet in pending:
                delivered.add(packet); append('deliver', packet=packet, refresh=False)
            latest = observe(binary, scenario)
            if any(e['kind'] == 'network_interrupted' for r in latest['records'] if r['peer'] == 1 for e in r['events']):
                break
        append('poll', peer=0, at=2000000)
        append('poll', peer=1, at=2000001)
        if any(r['peer'] == 1 and e['kind'] == 'disconnected' for r in latest['records'] for e in r['events']):
            raise ValueError('partition terminal precedes the timeout poll')
        append('poll', peer=0, at=3000000)
        append('poll', peer=1, at=3000001)
        if not any(r['peer'] == 1 and e['kind'] == 'disconnected' for r in latest['records'] for e in r['events']):
            raise ValueError('partition starvation never reached the disconnect timeout')
    elif name == 'partition_heal':
        # A short confirmed prefix, then a bounded one-way starvation: peer 1
        # stops receiving everything from peer 0 while peer 0 keeps receiving
        # peer 1. Peer 1 latches network_interrupted past the notify bound and
        # predicts through the quiet stretch, the withheld burst then arrives
        # well below the disconnect timeout, network_resumed fires and the
        # missing inputs force a deep LOAD correction through the actual
        # public API; both peers resume confirming canonical history together
        # and the schedule ends synchronized instead of at a terminal.
        for _ in range(3):
            step(0); step(1); flush()
        starved = False
        for frame in range(6):
            now = 500000 + frame * 150000
            step(0, at=now); step(1, at=now + 1)
            pending = [p['id'] for p in latest['packets'] if p['id'] not in delivered and p['from'] == 1]
            for packet in pending:
                delivered.add(packet); append('deliver', packet=packet, refresh=False)
            latest = observe(binary, scenario)
            if any(e['kind'] == 'network_interrupted' for r in latest['records'] if r['peer'] == 1 for e in r['events']):
                starved = True
        if not starved:
            raise ValueError('partition heal never latched the notify bound')
        burst = [p['id'] for p in latest['packets'] if p['id'] not in delivered]
        if not burst:
            raise ValueError('partition heal withheld an empty burst')
        append('deliver', packet=burst[0], at=1500000)
        for packet in burst[1:]:
            delivered.add(packet); append('deliver', packet=packet, refresh=False)
        delivered.add(burst[0])
        latest = observe(binary, scenario)
        if not any(e['kind'] == 'network_resumed' for r in latest['records'] if r['peer'] == 1 for e in r['events']):
            raise ValueError('partition heal never resumed the starved peer')
        for frame in range(3):
            now = 1600000 + frame * 150000
            step(0, at=now); step(1, at=now + 1)
            flush()
            if frame == 0:
                # Re-deliver the first withheld report on purpose: the starved
                # peer answers the same echoed token a second time, and the fed
                # peer must re-measure that duplicate identically instead of
                # freezing its RTT at the first reply.
                append('deliver', packet=burst[0])
                flush()
        flush()
        for peer in range(2):
            step(peer)
            flush()
        append('poll', peer=0, at=2500000)
        append('poll', peer=1, at=2500001)
    elif name == 'partition_heal_mesh':
        # Three players confirm a real prefix on every link, then lose the direct
        # 1<->2 link in both directions while both cut peers keep their links to
        # peer 0. Each cut endpoint latches its own remote-attributed
        # network_interrupted past the notify bound and predicts through the quiet
        # stretch, the withheld burst then arrives well below the disconnect
        # timeout, both endpoints observe network_resumed and the missing inputs
        # force deep LOAD corrections through the actual public API; all three
        # peers resume confirming canonical history together and the schedule
        # ends synchronized with no terminal.
        scenario['players'] = 3
        for _ in range(3):
            for peer in range(3):
                step(peer)
            flush()
        starved = False
        for frame in range(6):
            now = 500000 + frame * 150000
            for peer in range(3):
                step(peer, at=now + peer)
            flush_around(cut)
            latched = {(r['peer'], e.get('peer')) for r in latest['records'] for e in r['events']
                       if e['kind'] == 'network_interrupted'}
            if {(1, 2), (2, 1)} <= latched:
                starved = True
        if not starved:
            raise ValueError('partition heal mesh never attributed both cut interruptions')
        burst = [p['id'] for p in latest['packets'] if p['id'] not in delivered and cut(p)]
        if not burst:
            raise ValueError('partition heal mesh withheld an empty burst')
        for packet in burst:
            delivered.add(packet); append('deliver', packet=packet, at=1500000, refresh=False)
        latest = observe(binary, scenario)
        resumed = sum(e['kind'] == 'network_resumed' for r in latest['records'] for e in r['events'])
        if resumed != 2:
            raise ValueError(f'partition heal mesh resumed {resumed} cut endpoints')
        for frame in range(3):
            now = 1600000 + frame * 150000
            for peer in range(3):
                step(peer, at=now + peer)
            flush_around(lambda packet: False)
        flush_around(lambda packet: False)
        for peer in range(3):
            step(peer)
            flush_around(lambda packet: False)
        append('poll', peer=0, at=2500000)
        append('poll', peer=1, at=2500001)
        append('poll', peer=2, at=2500002)
    elif name == 'partition_fairness':
        # Long-lived partition fairness: each of the mesh's three links takes
        # exactly one starvation turn in rotation. A three-round confirmed
        # prefix opens the schedule; every starvation turn then withholds one
        # link in both directions for six rounds — long enough for both cut
        # endpoints to latch their own remote-attributed network_interrupted
        # past the shared notify bound — before the withheld burst arrives
        # inside the disconnect timeout. Exactly the two cut endpoints resume,
        # the missing inputs force deep LOAD corrections through the public
        # advance API, and three confirmed rounds re-synchronize the mesh, so
        # every later turn opens on links that all just confirmed. After all
        # three rotations the schedule ends synchronized with no terminal: no
        # link, and no peer, is treated differently by the schedule. The
        # rotation bases keep each turn's early rounds just under the notify
        # bound (rotation 0 frame 0 sits 45 us short; later turns 20-22 us
        # short at frame 2), which only positions the latches; moving a base,
        # the spacing or the prefix length moves them, so re-check the trace
        # after any such edit.
        scenario['players'] = 3
        for _ in range(3):
            for peer in range(3):
                step(peer)
            flush_around(lambda packet: False)
        resumed = 0
        for rotation, (pair, base) in enumerate((((1, 2), 500000), ((0, 1), 2100000), ((0, 2), 3700000))):
            def cut(packet, pair=pair):
                return {packet['from'], packet['to']} == set(pair)
            for frame in range(6):
                now = base + frame * 150000
                for peer in range(3):
                    step(peer, at=now + peer)
                flush_around(cut)
            latched = {(r['peer'], e.get('peer')) for r in latest['records'] for e in r['events']
                       if e['kind'] == 'network_interrupted'}
            if not {pair, pair[::-1]} <= latched:
                raise ValueError(f'partition fairness rotation {rotation} never attributed both cut interruptions')
            burst = [p['id'] for p in latest['packets'] if p['id'] not in delivered and cut(p)]
            if not burst:
                raise ValueError(f'partition fairness rotation {rotation} withheld an empty burst')
            for packet in burst:
                delivered.add(packet); append('deliver', packet=packet, at=base + 1000000, refresh=False)
            latest = observe(binary, scenario)
            count = sum(e['kind'] == 'network_resumed' for r in latest['records'] for e in r['events'])
            if count != resumed + 2:
                raise ValueError(f'partition fairness rotation {rotation} resumed {count - resumed} cut endpoints')
            resumed = count
            for frame in range(3):
                now = base + 1100000 + frame * 150000
                for peer in range(3):
                    step(peer, at=now + peer)
                flush_around(lambda packet: False)
        for frame in range(3):
            now = 5200000 + frame * 150000
            for peer in range(3):
                step(peer, at=now + peer)
            flush_around(lambda packet: False)
        final = sum(e['kind'] == 'network_resumed' for r in latest['records'] for e in r['events'])
        if final != resumed:
            raise ValueError(f'partition fairness tail fired {final - resumed} extra resumes')
        append('poll', peer=0, at=5600000)
        append('poll', peer=1, at=5600001)
        append('poll', peer=2, at=5600002)
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

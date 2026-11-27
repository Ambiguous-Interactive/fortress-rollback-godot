"""Verify the pinned source receives the original decision at its exact deadline."""
from drop_history_contract import REVISION, check_source_content, check_source_operation, fields, integer, original_history, require, same


def check_commit_deadline(source, offset):
    label = 'source COMMIT deadline'
    fields(source, 'upstream_revision offset_us started_us release_us ready ready_received commit commit_received '
                   'abort state dropped_before dropped frontier row_before row_after advance frame_before frame_after', label)
    require(same(source['upstream_revision'], REVISION), label + ' revision')
    require(same(source['started_us'], 9000) and same(source['offset_us'], offset)
            and same(source['release_us'], 2_009_000 + offset), label + ' clock')
    observed_order = []
    for name, kind in [('ready', 'DropReport'), ('commit', 'DropCommit')]:
        emitted, received = source[name], source[name + '_received']
        for packet in (emitted, received):
            fields(packet, 'from to body emission order', label + ' ' + name)
            integer(packet['order'], 1, 8192, label + ' observation order')
            integer(packet['emission'], 0, 4095, label + ' emission')
        require(same([emitted['from'], emitted['to']], [0, 1]), label + ' route')
        require(received['order'] > emitted['order']
                and same(received, {**emitted, 'order': received['order']}), label + ' decision receipt')
        fields(emitted['body'], kind, label + ' body')
        content = emitted['body'][kind]
        check_source_content(kind, content, label, 1, 1)
        check_source_operation(content['operation'], label + ' operation', 1)
        require(same(content['cut'], 8), label + ' cut')
        if name == 'ready':
            require(content['stage'] == 'Ready' and same(content['participant'], 0), label + ' coordinator READY')
        observed_order.append((emitted['order'], received['order']))
    ready_emitted, ready_received = observed_order[0]
    commit_emitted, commit_received = observed_order[1]
    require(ready_emitted < commit_emitted < ready_received == commit_received - 1, label + ' original decision batch')
    expected_row = original_history()[4]['inputs']
    require(same(source['frontier'], 4) and same(source['row_before'], expected_row)
            and same(source['row_after'], expected_row), label + ' original confirmed row')
    require(same(source['dropped_before'], 0), label + ' premature freeze')
    early = offset < 0
    require(same(source['dropped'], int(early))
            and source['state'] == ('Running' if early else 'Synchronizing')
            and source['advance'] == ('ok' if early else 'not_synchronized')
            and same(source['frame_before'], 6) and same(source['frame_after'], 7 if early else 6), label + ' outcome')
    abort = source['abort']
    if early:
        require(abort is None, label + ' premature abort')
    else:
        fields(abort, 'from to body emission order', label + ' timeout abort')
        integer(abort['order'], commit_received + 1, 8192, label + ' timeout abort order')
        integer(abort['emission'], source['commit']['emission'] + 1, 4095, label + ' timeout abort emission')
        operation = source['commit']['body']['DropCommit']['operation']
        require(same([abort['from'], abort['to'], abort['body']],
                     [1, 0, {'DropAbort': {'operation': operation, 'reason': 'Timeout'}}]), label + ' timeout abort')


def deadline_controls(expired):
    # Value: protects=actual certificate cutoff; fails_when=mutated delivery, abort, history or frame evidence passes; why_new=retry traces never expire; seam=none
    controls = {
        'deadline_clock': ('clock', {'release_us': 2_008_999}),
        'deadline_missing_abort': ('timeout abort schema', {'abort': None}),
        'deadline_early_freeze': ('premature freeze', {'dropped_before': 1}),
        'deadline_late_advance': ('outcome', {'frame_after': 7}),
        'deadline_rewritten_history': ('original confirmed row', {'row_after': ['00', '01', '02']}),
        'deadline_changed_received_commit': ('decision receipt', {'commit_received': expired['ready_received']}),
    }
    for name, (diagnostic, mutation) in controls.items():
        try:
            check_commit_deadline({**expired, **mutation}, 0)
        except ValueError as error:
            require(str(error) == 'drop history: source COMMIT deadline ' + diagnostic, name + ' unrelated failure: ' + str(error))
        else:
            raise ValueError('drop history: negative control survived: ' + name)
    return list(controls)

"""Validate the live selected donor packet and the controller's two outcomes."""
from copy import deepcopy
import re
import struct

from .webrtc_drop import _peer_id, _room_physical, _withheld_input_range


def _require(condition, detail):
    if not condition:
        raise ValueError(f'peer-drop donor history {detail}')


def _sample(frame, slot):
    return (17 * frame + 31 * slot + 1) & 255


def _packet(held, donor_slot, target_slot, recipient_slot):
    encoded = held.get('packet')
    _require(isinstance(encoded, str) and re.fullmatch(r'[0-9a-f]{224}', encoded), 'packet missing')
    packet = bytes.fromhex(encoded)
    _require(packet[:8] == b'FRGP\x03\x00\x0c\x00' and packet[8:24].hex() == held.get('session_id')
             and packet[24:32].hex() == _peer_id(held['donor']) and packet[32:40] != b'\x00' * 8
             and int.from_bytes(packet[40:44], 'little') == len(packet) - 44, 'packet attribution differs')
    phase, stage, reason, reserved, coordinator, era, operation, target_digest, cut, first, donor, digest, index, count, witness, pad, targets = (
        struct.unpack_from('<BBBBHHIQiiiQHHBBI', packet, 44))
    _require((phase, stage, reason, reserved, coordinator, cut, first, donor, digest, index, count, witness, pad, targets)
             == (3, 5, 0, 0, recipient_slot, 6, 4, donor_slot, 0, 0, 1, 0, 0, 3)
             and era > 0 and operation == held.get('operation') and operation > 0 and f'{target_digest:016x}' == held.get('target_set_digest'),
             'packet differs from the selected operation')
    slot, generation, payload_size = struct.unpack_from('<BHI', packet, 94)
    _require(slot == target_slot and generation == held.get('target_generation') and payload_size == 3
             and packet[101:104] == bytes(_sample(frame, target_slot) for frame in range(4, 7))
             and int.from_bytes(packet[104:112], 'little') != 0, 'packet lacks the original target samples')


def _prefix(state):
    _require(isinstance(state, dict) and type(state.get('frame')) is int and state['frame'] == 8 and type(state.get('confirmed')) is int
             and 2 <= state['confirmed'] <= 3
             and isinstance(state.get('state'), str) and re.fullmatch(r'[0-9a-f]{32}', state['state'])
             and isinstance(state.get('replay_sha256'), str) and re.fullmatch(r'[0-9a-f]{64}', state['replay_sha256']),
             'recipient boundary invalid')
    _require(state['state'][:8] == struct.pack('<I', state['frame']).hex(), 'recipient state frame header differs')
    replay = state.get('replay')
    _require(isinstance(replay, list) and len(replay) == state['confirmed'] + 1, 'replay extent differs')
    values = [0, 0, 0]
    canonical = []
    for frame, row in enumerate(replay):
        source = [_sample(frame, slot) for slot in range(3)]
        _require(row == [[f'{sample:02x}', 1] for sample in source], 'replay changed original confirmed inputs')
        values = [(value * 33 + sample) & 0xffffffff for value, sample in zip(values, source)]
        canonical.append(struct.pack('<4I', frame + 1, *values).hex())
    _require(state.get('canonical') == canonical, 'confirmed simulation differs from original inputs')


def _fence(fence, donor, live, previous=None):
    _require(isinstance(fence, dict) and fence.get('route') == 'restart_required' and fence.get('error') == 2
             and fence.get('action_ready') == donor and fence.get('events') == [donor] and sorted(fence.get('live_roster', [])) == live
             and fence.get('connected') is True and fence.get('authenticated') is True and fence.get('mesh_detached') is True
             and type(fence.get('revision')) is int and fence['revision'] > 0
             and (previous is None or fence['revision'] == previous + 1), 'SDK player-left and adapter fence differ')


def validate_donor_history(result, physical_close):
    _require(result.get('passed') is True and result.get('peerDrop') is True and result.get('dropMissing') is True
             and result.get('dropHistoryLost') is False and result.get('dropDonorProcess') is physical_close,
             'witness mode differs')
    rooms = result.get('records')
    _require(isinstance(rooms, list) and len(rooms) == 1 and rooms[0].get('players') == 3, 'room inventory differs')
    controller = rooms[0].get('donorHistory')
    _require(isinstance(controller, dict) and controller.get('action') == ('context_closed' if physical_close else 'history_released')
             and type(controller.get('donor_index')) is int and controller['donor_index'] in (0, 1), 'controller action missing')
    held = controller.get('held')
    _require(isinstance(held, dict), 'received hold missing')
    donor, target, recipient = (held.get(key) for key in ('donor', 'target', 'recipient'))
    for uuid in (donor, target, recipient):
        _peer_id(uuid)
    _require(len({donor, target, recipient}) == 3 and recipient < donor, 'role identities differ')
    roster = sorted((donor, target, recipient))
    donor_index = controller['donor_index']
    page_uuids = controller.get('page_uuids')
    _require(isinstance(page_uuids, list) and len(page_uuids) == 3 and page_uuids[donor_index] == donor
             and page_uuids[1 - donor_index] == recipient and page_uuids[2] == target, 'controller original page identities differ')
    _require(held.get('roster') == roster and type(held.get('revision')) is int and held['revision'] >= 0
             and isinstance(held.get('session_id'), str) and re.fullmatch(r'[0-9a-f]{32}', held['session_id']), 'hold identity differs')
    donor_slot, target_slot, recipient_slot = (roster.index(uuid) for uuid in (donor, target, recipient))
    _packet(held, donor_slot, target_slot, recipient_slot)
    _prefix(held.get('state'))

    observed = controller.get('observed')
    _require(isinstance(observed, dict) and observed.get('uuid') == donor and observed.get('ready') is True
             and observed.get('frame') == 7 and isinstance(observed.get('room'), str) and observed['room']
             and observed.get('open_sockets') == 1 and observed.get('outcome', False) is None
             and observed.get('first_history') == held['packet']
             and all(type(observed.get(key)) is int and observed[key] >= 1 for key in ('rtc_sent', 'rtc_received')),
             'selected donor was not live before the controller action')
    pages = rooms[0].get('peers')
    _require(isinstance(pages, list) and len(pages) == (2 if physical_close else 3), 'browser outcome count differs')
    rows = {}
    page_indexes = [index for index in range(3) if not physical_close or index != donor_index]
    for index, page in zip(page_indexes, pages, strict=True):
        _, witness = _room_physical(page)
        records = witness.get('records', [])
        _require(witness.get('passed') is True and len(records) == 1 and isinstance(records[0], dict), 'browser outcome missing')
        uuid = page_uuids[index]
        _require(type(page.get('page_index')) is int and page['page_index'] == index and records[0].get('uuid') == uuid,
                 'browser outcome page identity differs')
        rows[uuid] = records[0]
    live = sorted((target, recipient))
    _require(_withheld_input_range(rows[target].get('missing_inputs'), 4, target_slot, _peer_id(recipient))
             and rows[target].get('roster') == roster and rows[target].get('session_id') == held['session_id'],
             'target withheld range differs')
    result_row = rows[recipient]
    if physical_close:
        _fence(rows[target].get('donor_fence'), donor, live)
        _fence(result_row.get('fence'), donor, live, held['revision'])
        _require(result_row.get('held') == held and result_row.get('after') == held['state'] and result_row.get('refusal') == 2
                 and result_row.get('rollback') == {'lifecycle': 'running', 'barrier': 'pending', 'events': ['peer_drop_pending'],
                                                    'installed': False, 'certified': False, 'target_freeze': -1, 'donor_freeze': -1},
                 'adapter refusal changed pending rollback state')
    else:
        _require(result_row.get('donor_history_hold') == held and result_row.get('history_installed') is True
                 and result_row.get('state') == 'committed' and result_row.get('freeze_frame') == 6
                 and rows[donor].get('certified') is True, 'held packet delivery did not certify')
    return result



def check_donor_history_controls(result):
    control = deepcopy(result)
    room = control['records'][0]
    controller = room['donorHistory']
    diagnostics = []

    def reject(expected):
        try:
            validate_donor_history(control, True)
        except ValueError as error:
            if str(error) != f'peer-drop donor history {expected}':
                raise
            diagnostics.append(str(error))
        else:
            raise ValueError(f'peer-drop donor history control passed with changed {expected}')

    original = controller['donor_index']
    controller['donor_index'] = 1 - original
    reject('controller original page identities differ')
    controller['donor_index'] = original
    room['peers'].reverse()
    reject('browser outcome page identity differs')
    room['peers'].reverse()
    state = controller['held']['state']
    state['state'] = struct.pack('<I', state['frame'] + 1).hex() + state['state'][8:]
    reject('recipient state frame header differs')
    return {'diagnostics': diagnostics}

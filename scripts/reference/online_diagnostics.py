"""Validate public diagnostic downloads against independent browser callback observations."""
import json

COUNTERS = {'rollback_count', 'resimulated_frames', 'advanced_frames', 'prediction_stalls', 'last_rollback_depth', 'max_rollback_depth'}
PEER_FIELDS = {'index', 'state', 'pending_frames', 'last_received_frame', 'last_acked_frame', 'round_trip_time_ms', 'average_frame_advantage'}
REPORT_FIELDS = {'schema', 'engine', 'transport', 'current_frame', 'confirmed_frame', 'lifecycle', 'reason', 'failure_frame',
                 'pending_rollback_frame', 'frames_ahead', 'statistics', 'peers', 'failure'}


def integer(value, lower=0, upper=2**63 - 1):
    if type(value) is not int or not lower <= value <= upper:
        raise ValueError('diagnostic integer outside domain')


def event(value, peers, depth=0):
    if not isinstance(value, dict) or value.keys() - {'kind', 'frame', 'reason', 'field', 'peer_index', 'local_checksum', 'remote_checksum', 'terminal_cause'}:
        raise ValueError('diagnostic event contains unapproved fields')
    if not value:
        return
    if not isinstance(value.get('kind'), str) or not 1 <= len(value['kind']) <= 64:
        raise ValueError('diagnostic event kind missing')
    if 'field' in value and (not isinstance(value['field'], str) or not 1 <= len(value['field']) <= 64):
        raise ValueError('diagnostic mismatch field invalid')
    if 'frame' in value:
        integer(value['frame'], -1, 2**31 - 1)
    if 'peer_index' in value:
        integer(value['peer_index'], -1, peers - 1)
    if 'reason' in value and not (type(value['reason']) is int or isinstance(value['reason'], str) and len(value['reason']) <= 64):
        raise ValueError('diagnostic event reason invalid')
    for field in ('local_checksum', 'remote_checksum'):
        if field in value and (not isinstance(value[field], str) or len(value[field]) != 32
                               or any(char not in '0123456789abcdef' for char in value[field])):
            raise ValueError('diagnostic checksum invalid')
    if 'terminal_cause' in value:
        if depth >= 2 or not isinstance(value['terminal_cause'], list) or len(value['terminal_cause']) > peers + 1:
            raise ValueError('diagnostic terminal causes exceed bounds')
        for cause in value['terminal_cause']:
            event(cause, peers, depth + 1)


def validate_download(value):
    if not isinstance(value, dict) or value.get('filename') != 'fortress-diagnostics.json':
        raise ValueError('missing real diagnostic download')
    report = value.get('report')
    if not isinstance(report, dict) or report.keys() != REPORT_FIELDS or report['schema'] != 'fortress-peer-diagnostics-v1':
        raise ValueError('diagnostic schema or privacy fields differ')
    if len(json.dumps(report).encode('utf-8')) > 32768:
        raise ValueError('diagnostic download exceeds byte bound')
    if not isinstance(report['engine'], str) or not 1 <= len(report['engine']) <= 128:
        raise ValueError('diagnostic engine identity missing')
    for field in ('current_frame', 'confirmed_frame', 'failure_frame', 'pending_rollback_frame', 'frames_ahead'):
        integer(report[field], -2**31, 2**31 - 1)
    for field in ('lifecycle', 'reason'):
        integer(report[field], 0, 255)
    counts = report['statistics']
    if not isinstance(counts, dict) or counts.keys() != COUNTERS:
        raise ValueError('diagnostic counters missing')
    for count in counts.values():
        integer(count)
    if counts['advanced_frames'] != report['current_frame'] or counts['last_rollback_depth'] > counts['max_rollback_depth']:
        raise ValueError('diagnostic completed work inconsistent')
    peers = report['peers']
    if not isinstance(peers, list) or not 1 <= len(peers) <= 7:
        raise ValueError('diagnostic peer inventory missing')
    for index, peer in enumerate(peers):
        if not isinstance(peer, dict) or peer.keys() != PEER_FIELDS or peer['index'] != index:
            raise ValueError('diagnostic peer privacy fields differ')
        if peer['state'] not in ('initializing', 'synchronizing', 'running', 'terminated', 'failed'):
            raise ValueError('diagnostic peer state invalid')
        integer(peer['index'], 0, len(peers) - 1)
        for field in PEER_FIELDS - {'index', 'state'}:
            integer(peer[field], -2**31)
    transport = report['transport']
    if not isinstance(transport, dict) or transport.keys() != {'relay_links', 'pending_packets', 'pending_bytes'}:
        raise ValueError('diagnostic transport privacy fields differ')
    for count in transport.values():
        integer(count)
    event(report['failure'], len(peers))
    before, after = value.get('before'), value.get('after')
    if not isinstance(before, dict) or not isinstance(after, dict) or after.get('storage_calls') != 0:
        raise ValueError('diagnostic export used unavailable browser storage')
    integer(after.get('storage_calls'))
    for observation in (before, after):
        integer(observation.get('restores'))
        integer(observation.get('frame'))
    if not before['restores'] <= counts['rollback_count'] <= after['restores']:
        raise ValueError('diagnostic rollback count differs from real game callbacks')
    if not before['frame'] <= report['current_frame'] <= after['frame']:
        raise ValueError('diagnostic frame differs from game observation')

"""Raw packet contracts for the reviewed Fortress source and upgrade candidate."""

import json

from contract import fields, integer

REVIEWED_REVISION = 'd124c89080004d96971a629bb0427056ee1805e3'
RECOVERY_REVISION = '25e8020d1a5fd40c4f16b37f97b5ec5329a8566d'
_WIRE_VERSIONS = {REVIEWED_REVISION: 2, RECOVERY_REVISION: 6}


def wire_version(revision):
    if type(revision) is not str or revision not in _WIRE_VERSIONS:
        raise ValueError('unsupported upstream wire revision')
    return _WIRE_VERSIONS[revision]


def decode_trace(contents):
    """Reject ambiguous raw evidence before object inventory checks."""
    def unique_object(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError(f'duplicate trace field: {key}')
            result[key] = value
        return result

    return json.loads(contents, object_pairs_hook=unique_object)


def _require_supported(wire):
    if type(wire) is not int or wire not in _WIRE_VERSIONS.values():
        raise ValueError('unsupported upstream wire version')


def header(raw, wire, *, synchronizing=False):
    _require_supported(wire)
    fields(raw, 'header body', 'upstream packet' if synchronizing else 'raw packet')
    value = raw['header']
    fields(value, 'conn_id flags protocol_version sentinel', 'upstream header' if synchronizing else 'header')
    integer(value['conn_id'], 0 if synchronizing else 1, 0xffffffff, 'connection')
    integer(value['flags'], 0, 0, 'flags')
    integer(value['protocol_version'], wire, wire, 'header version' if synchronizing else 'protocol version')
    if type(value['sentinel']) is not list or len(value['sentinel']) != 2:
        raise ValueError('sentinel inventory')
    for actual, expected in zip(value['sentinel'], (245, 82)):
        integer(actual, expected, expected, 'sentinel byte')


def checksum_basis(raw, wire):
    """Read one exact versioned checksum body without narrowing the basis token."""
    _require_supported(wire)
    fields(raw, 'frame checksum basis_token' if wire == 6 else 'frame checksum', 'raw control')
    if wire == 6:
        token = raw['basis_token']
        integer(token, 0, (1 << 64) - 1, 'checksum basis token')
        return token
    return 0

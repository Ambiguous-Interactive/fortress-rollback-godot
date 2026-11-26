"""Own and verify a local STUN-only listener for browser ICE witnesses."""
from contextlib import contextmanager
from ipaddress import IPv4Address
import os
import socket
import struct
import subprocess

from signalfish_live_probe import wait_ready

STUN_COOKIE = 0x2112A442


def local_port(address='127.0.0.1'):
    with socket.socket() as selection:
        selection.bind((address, 0))
        return selection.getsockname()[1]


def stun_address():
    candidate = os.environ.get('FORTRESS_STUN_ADDRESS')
    if not candidate:
        with socket.socket(type=socket.SOCK_DGRAM) as route:
            # Reading the selected route does not send a datagram.
            route.connect(('192.0.2.1', 9))
            candidate = route.getsockname()[0]
    address = IPv4Address(candidate)
    if address.is_loopback or address.is_unspecified:
        raise ValueError('browser STUN witness requires a non-loopback IPv4 interface')
    return str(address)


def verify_stun_binding(address, port):
    request = struct.pack('!HHI', 1, 0, STUN_COOKIE) + os.urandom(12)
    try:
        with socket.socket(type=socket.SOCK_DGRAM) as probe:
            probe.settimeout(2)
            probe.connect((address, port))
            local_address, local_port_number = probe.getsockname()
            probe.send(request)
            response = probe.recv(2048)
    except OSError as error:
        raise ValueError('local listener did not answer a STUN Binding request') from error
    if (len(response) <= 20 or response[:2] != b'\x01\x01' or response[4:20] != request[4:]
            or int.from_bytes(response[2:4], 'big') != len(response) - 20):
        raise ValueError('invalid STUN Binding response')
    expected = struct.pack('!BBHI', 0, 1, local_port_number ^ (STUN_COOKIE >> 16), int(IPv4Address(local_address)) ^ STUN_COOKIE)
    offset = 20
    mapped = False
    while offset + 4 <= len(response):
        kind, size = struct.unpack_from('!HH', response, offset)
        offset += 4
        end = offset + ((size + 3) & ~3)
        if end > len(response):
            raise ValueError('truncated STUN Binding attribute')
        if kind == 0x0020:
            if mapped or response[offset:offset + size] != expected:
                raise ValueError('invalid STUN Binding address')
            mapped = True
        offset = end
    if not mapped or offset != len(response):
        raise ValueError('missing valid STUN Binding address')


@contextmanager
def local_stun(tool, root, log):
    address = stun_address()
    port = local_port(address)
    command = [str(tool), '-n', '--stun-only', '--no-auth', '--no-cli', '--no-tls', '--no-dtls',
               f'--listening-ip={address}', f'--relay-ip={address}', '--relay-threads=1', f'--listening-port={port}',
               f'--pidfile={root / "stun.pid"}', f'--userdb={root / "stun.sqlite"}', '--log-file=stdout', '--simple-log']
    with log.open('wb') as stream, subprocess.Popen(command, stdout=stream, stderr=subprocess.STDOUT) as server:
        try:
            wait_ready(server, port, address)
            verify_stun_binding(address, port)
            yield f'stun:{address}:{port}'
            if server.poll() is not None:
                raise ValueError('local STUN listener exited during gameplay')
        finally:
            if server.poll() is None:
                server.kill()
                server.wait(timeout=5)

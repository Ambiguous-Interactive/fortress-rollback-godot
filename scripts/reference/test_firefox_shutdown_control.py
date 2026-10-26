"""Value: reject malformed, truncated or unbounded shutdown-control frames before accepting lifecycle evidence."""
import json
import ctypes
import os
from pathlib import Path
import select
import signal
import socket
import subprocess
import sys
import time
import unittest
from unittest import mock

import firefox_shutdown_control as control


class ShutdownFramingTests(unittest.TestCase):
    def peer(self, payload):
        receiver, sender = socket.socketpair()
        self.addCleanup(receiver.close)
        self.addCleanup(sender.close)
        sender.sendall(payload)
        sender.shutdown(socket.SHUT_WR)
        return control.Marionette(receiver, time.monotonic() + 15)

    def test_utf8_payload_and_adjacent_frames_are_read_exactly(self):
        values = [{'name': 'é'}, [1, 2, None, {'value': 0}]]
        payloads = [json.dumps(value, ensure_ascii=False).encode('utf-8') for value in values]
        peer = self.peer(b''.join(str(len(value)).encode() + b':' + value for value in payloads))
        self.assertEqual([peer.receive(), peer.receive()], values)

    def test_malformed_or_truncated_frames_fail(self):
        for payload in (b'', b'1', b'2:{', b':', b'-1:{}', b'0:', b'65537:', b'1234567:', b'x:', b'1:\xff', b'3:NaN', b'3:{}x'):
            with self.subTest(payload=payload), self.assertRaises((ValueError, UnicodeError)):
                self.peer(payload).receive()

    def test_absolute_deadline_cannot_be_extended_by_partial_reads(self):
        peer = self.peer(b'2:{}')
        with mock.patch.object(control.time, 'monotonic', side_effect=[0, 14, 15]):
            with self.assertRaisesRegex(ValueError, 'deadline'):
                peer.receive()

    def test_response_must_match_integer_sequence_and_report_success(self):
        for value in ([1, 1, None, {'value': 0}], [True, 1, None, {}], [1, True, None, {}], [1, 2, None, {}], [1, 1, {'error': 'failed'}, None], {}):
            payload = json.dumps(value).encode()
            peer = self.peer(str(len(payload)).encode() + b':' + payload)
            if value == [1, 1, None, {'value': 0}]:
                self.assertEqual(peer.call('test', {}), {'value': 0})
            else:
                with self.subTest(value=value), self.assertRaises(ValueError):
                    peer.call('test', {})

    def test_oversized_requests_fail_before_sending(self):
        peer = self.peer(b'')
        with self.assertRaisesRegex(ValueError, 'request too large'):
            peer.call('test', {'data': 'x' * control.LIMIT})


@unittest.skipUnless(sys.platform == 'linux', 'Firefox shutdown process groups require Linux /proc')
class ShutdownProcessGroupTests(unittest.TestCase):
    def fixture(self):
        libc = ctypes.CDLL(None, use_errno=True)
        previous = ctypes.c_int()
        self.assertEqual(libc.prctl(37, ctypes.byref(previous), 0, 0, 0), 0)
        self.assertEqual(libc.prctl(36, 1, 0, 0, 0), 0)
        self.addCleanup(lambda: libc.prctl(36, previous.value, 0, 0, 0))
        child = 'import signal,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);print("ready",flush=True);time.sleep(60)'
        leader = ('import subprocess,sys,time;'
                  f'child=subprocess.Popen([sys.executable,"-c",{child!r}],stdout=subprocess.PIPE,text=True);'
                  'child.stdout.readline();print(child.pid,flush=True);time.sleep(60)')
        process = subprocess.Popen([sys.executable, '-c', leader], stdout=subprocess.PIPE, text=True, start_new_session=True)
        child_pid = None

        def cleanup():
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait(timeout=5)
            process.stdout.close()
            if child_pid is not None:
                deadline = time.monotonic() + 2
                while time.monotonic() < deadline:
                    try:
                        if os.waitpid(child_pid, os.WNOHANG)[0]:
                            return
                    except ChildProcessError:
                        return
                    time.sleep(.01)
                self.fail('owned descendant was not reaped')

        self.addCleanup(cleanup)
        self.assertTrue(select.select([process.stdout], [], [], 5)[0], 'fixture child did not become ready')
        child_pid = int(process.stdout.readline())
        return process, child_pid

    def test_cleanup_stops_descendants_even_after_the_leader_exits(self):
        for leader_exited in (False, True):
            with self.subTest(leader_exited=leader_exited):
                process, child_pid = self.fixture()
                if leader_exited:
                    process.terminate()
                    process.wait(timeout=5)
                signals = control.cleanup_group(process, time.monotonic() + 2)
                self.assertEqual(signals, ['SIGTERM', 'SIGKILL'])
                status = Path(f'/proc/{child_pid}/stat').read_text().rsplit(')', 1)[1].split()[0]
                self.assertIn(status, ('Z', 'X'), 'SIGTERM-ignoring descendant survived cleanup')

    def test_natural_group_wait_rejects_a_surviving_writer(self):
        process, _ = self.fixture()
        process.terminate()
        process.wait(timeout=5)
        self.assertFalse(control.wait_group(process, time.monotonic() + .05))


if __name__ == '__main__':
    unittest.main()

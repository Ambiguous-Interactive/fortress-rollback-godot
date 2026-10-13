"""Value: process death and verified fresh readiness cannot be replaced by a socket cut."""
import json
import os
from pathlib import Path
import socket
import tempfile
import unittest
from urllib.request import Request, urlopen

from browser.owned_server import OwnedServer


class OwnedServerTests(unittest.TestCase):
    def test_actual_process_exit_restart_and_same_endpoint(self):
        with tempfile.TemporaryDirectory() as temporary:
            executable = Path(temporary) / 'service.py'
            executable.write_text('#!/usr/bin/env python3\nimport os, socket, json\n'
                'port = json.loads(os.environ["SIGNAL_FISH_CONFIG_JSON"])["port"]\n'
                'with socket.socket() as listener:\n'
                ' listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)\n'
                ' listener.bind(("127.0.0.1", port))\n listener.listen()\n'
                ' while True:\n  connection, _ = listener.accept()\n  connection.close()\n')
            executable.chmod(0o755)
            with socket.socket() as selection:
                selection.bind(('127.0.0.1', 0))
                port = selection.getsockname()[1]
            environment = {'PATH': os.environ['PATH'], 'SIGNAL_FISH_CONFIG_JSON': json.dumps({'port': port})}
            with (Path(temporary) / 'service.log').open('wb') as log:
                with OwnedServer(executable, environment, port, log) as owner:
                    old = owner.process
                    def request(kind):
                        with urlopen(Request(owner.url + '/' + kind, data=b'', method='POST'), timeout=20) as response:
                            return json.load(response)
                    stop = request('stop')
                    self.assertEqual(stop, {'kind': 'stop', 'method': 'sigkill', 'pid': old.pid, 'exit_code': -9, 'terminal': True})
                    self.assertEqual(old.poll(), -9)
                    with self.assertRaises(OSError):
                        socket.create_connection(('127.0.0.1', port), timeout=0.1)
                    start = request('start')
                    self.assertNotEqual(start['pid'], old.pid)
                    self.assertTrue(start['live'] and start['ready'])
                    self.assertEqual(start['previous_pid'], old.pid)
                    self.assertEqual(start['port'], port)
                    with socket.create_connection(('127.0.0.1', port), timeout=0.1):
                        owner.verify_live()
                    with self.assertRaisesRegex(ValueError, 'out of order'):
                        owner.command('start')
                    owner.stop()
                    executable.write_text('changed binary')
                    with self.assertRaisesRegex(ValueError, 'binary changed'):
                        owner.command('start')
                self.assertIsNotNone(owner.process.poll())

    def test_unexpected_exit_is_not_intentional_restart_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            executable = Path(temporary) / 'crash.py'
            executable.write_text('#!/usr/bin/env python3\nraise SystemExit(7)\n')
            executable.chmod(0o755)
            with (Path(temporary) / 'service.log').open('wb') as log:
                owner = OwnedServer(executable, {'PATH': os.environ['PATH'], 'SIGNAL_FISH_CONFIG_JSON': '{}'}, 0, log)
                with self.assertRaisesRegex(ValueError, 'exited before readiness'):
                    with owner:
                        pass
                self.assertEqual(owner.process.poll(), 7)
                self.assertEqual(owner.events, [])

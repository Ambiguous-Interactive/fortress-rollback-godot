"""Value: protect live-witness capability separation, lifetime binding and bounded HTTP ingress."""
import http.client
import json
import socket
import threading
from unittest import mock

import spectator_control
import unittest

from spectator_control import Control, MAX_BYTES


class SpectatorControlTests(unittest.TestCase):
    def setUp(self):
        self.control = Control()
        self.control.start()
        self.addCleanup(self.control.close)
        self.admission = dict(viewer='viewer', room='room', host='host', identity='01' * 32, key='02' * 32,
                              digest='03' * 16, initial_state='00' * 24, players=2, width=1, neutral='00', seed='1701', rules='integer-v1')
        self.accept = {key: self.admission[key] for key in ['viewer', 'room', 'identity']}
        self.accept['packet'] = '04' * 88

    def request(self, path, role='viewer', body=None, raw=None, headers=None):
        peer = http.client.HTTPConnection('127.0.0.1', self.control.server.server_port, timeout=3)
        self.addCleanup(peer.close)
        token = self.control.host_token if role == 'host' else self.control.viewer_token
        fields = {'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'}
        fields.update(headers or {})
        peer.request('POST' if body is not None or raw is not None else 'GET', path,
                     body=json.dumps(body).encode() if raw is None and body is not None else raw, headers=fields)
        result = peer.getresponse()
        return result.status, json.loads(result.read())

    def test_capabilities_are_role_bound_and_nonascii_is_denied(self):
        self.assertEqual(self.request('/admission')[0], 404)
        self.assertEqual(self.request('/admit', body=self.admission)[0], 403)
        self.assertEqual(self.request('/admission', headers={'Authorization': 'Bearer foreign'})[0], 403)
        self.assertEqual(self.request('/admission', headers={'Authorization': 'Bearer \xe9'})[0], 403)
        self.assertIsNone(self.control.admission)
        self.assertEqual(self.request('/admit', 'host', self.admission)[0], 200)
        self.assertEqual(self.request('/admission', 'host')[0], 403)
        self.assertEqual(self.request('/admission'), (200, self.admission))
        self.assertEqual(self.request('/admit', 'host', self.admission)[0], 400)

    def test_accept_binds_lifetime_and_retains_exact_pending_bytes(self):
        self.assertEqual(self.request('/admit', 'host', self.admission)[0], 200)
        for field in ['viewer', 'room', 'identity']:
            with self.subTest(field=field):
                self.assertEqual(self.request('/accept', body={**self.accept, field: 'foreign'})[0], 403)
                self.assertEqual(self.request('/take', 'host'), (200, {}))
        self.assertEqual(self.request('/accept', 'host', self.accept)[0], 403)
        self.assertEqual(self.request('/accept', body=self.accept)[0], 200)
        self.assertEqual(self.request('/accept', body=self.accept)[0], 200)
        self.assertEqual(self.request('/accept', body={**self.accept, 'packet': '05' * 88})[0], 409)
        self.assertEqual(self.request('/take', 'host'), (200, self.accept))
        self.assertEqual(self.request('/take', 'host'), (200, {}))
        self.assertEqual(self.control.received, 2)

    def test_trickling_headers_cannot_block_close(self):
        entered = threading.Event()
        stopped = threading.Event()
        returned = threading.Event()
        handler = self.control.server.RequestHandlerClass

        class Observed(handler):
            def setup(self):
                super().setup()
                entered.set()

        self.control.server.RequestHandlerClass = Observed
        peer = socket.create_connection(('127.0.0.1', self.control.server.server_port), timeout=2)

        def trickle():
            while not stopped.wait(.02):
                try:
                    peer.sendall(b'a')
                except OSError:
                    return

        def close():
            self.control.close()
            returned.set()

        with mock.patch.object(spectator_control, 'REQUEST_SECONDS', .1, create=True):
            peer.sendall(b'GET /admission HTTP/1.1\r\nX-Hold: ')
            self.assertTrue(entered.wait(2), 'request reached service')
            sender = threading.Thread(target=trickle)
            sender.start()
            closer = threading.Thread(target=close)
            closer.start()
            try:
                self.assertTrue(returned.wait(5), 'absolute request deadline releases fixture shutdown')
            finally:
                stopped.set()
                try:
                    peer.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                peer.close()
                sender.join(timeout=2)
                closer.join(timeout=3)

    def test_http_body_and_declared_length_are_bounded(self):
        self.assertEqual(self.request('/unknown', raw=b'{}' + b' ' * (MAX_BYTES - 2))[0], 404)
        self.assertEqual(self.request('/unknown', raw=b' ' * (MAX_BYTES + 1))[0], 413)
        self.assertEqual(self.request('/unknown', raw=b'{}', headers={'Content-Length': '9' * 5000})[0], 413)
        self.assertEqual(self.request('/unknown', raw=b'', headers={'Transfer-Encoding': 'chunked'})[0], 400)
        peer = http.client.HTTPConnection('127.0.0.1', self.control.server.server_port, timeout=3)
        self.addCleanup(peer.close)
        peer.putrequest('POST', '/unknown')
        peer.putheader('Authorization', 'Bearer ' + self.control.viewer_token)
        peer.putheader('Content-Length', '2')
        peer.putheader('Content-Length', '3')
        peer.endheaders(b'{}')
        self.assertEqual(peer.getresponse().status, 413)
        self.assertEqual(self.request('/admit', 'host', raw=b'{')[0], 400)
        self.assertIsNone(self.control.admission)


if __name__ == '__main__':
    unittest.main()

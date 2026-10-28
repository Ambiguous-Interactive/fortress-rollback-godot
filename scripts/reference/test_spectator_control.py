"""Value: protect live-witness capability separation, lifetime binding and bounded HTTP ingress."""
import http.client
import json
import os
import subprocess
from http.server import BaseHTTPRequestHandler, HTTPServer
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

    def test_independent_viewer_provisioning_is_role_and_lifetime_bound(self):
        room = {'code': 'ROOM', 'game': 'fortress-spectator-browser'}
        self.assertEqual(self.request('/room')[0], 404)
        self.assertEqual(self.request('/room', body=room)[0], 403)
        self.assertEqual(self.request('/room', 'host', room)[0], 200)
        self.assertEqual(self.request('/room'), (200, room))
        self.assertEqual(self.request('/room', 'host', room)[0], 409)
        self.assertEqual(self.request('/viewer', 'host')[0], 404)
        self.assertEqual(self.request('/viewer', body={'viewer': 'viewer'})[0], 200)
        self.assertEqual(self.request('/viewer', 'host'), (200, {'viewer': 'viewer'}))
        self.assertEqual(self.request('/viewer')[0], 403)
        self.assertEqual(self.request('/viewer', body={'viewer': 'replacement'})[0], 409)
        self.assertEqual(self.request('/done', body={'complete': True})[0], 403)
        self.assertEqual(self.request('/admit', 'host', {**self.admission, 'viewer': 'foreign'})[0], 400)
        self.assertEqual(self.request('/admit', 'host', self.admission)[0], 200)
        self.assertEqual(self.request('/done', 'host')[0], 404)
        self.assertEqual(self.request('/done', body={'complete': True})[0], 403)
        self.assertEqual(self.request('/accept', body=self.accept)[0], 200)
        self.assertEqual(self.request('/done', body={'complete': True})[0], 200)
        self.assertEqual(self.request('/done', 'host'), (200, {'complete': True}))

    def cors_request(self, method, path='/admission', origin='http://127.0.0.1:8123', headers=None, body=None):
        peer = http.client.HTTPConnection('127.0.0.1', self.control.server.server_port, timeout=3)
        self.addCleanup(peer.close)
        fields = {'Origin': origin}
        fields.update(headers or {})
        peer.request(method, path, body=json.dumps(body).encode() if body is not None else None, headers=fields)
        response = peer.getresponse()
        raw = response.read()
        result = json.loads(raw) if response.getheader('Content-Type') == 'application/json' else None
        return response.status, dict(response.getheaders()), result

    def test_browser_preflight_is_origin_bound_without_admission(self):
        self.control.allowed_origin = 'http://127.0.0.1:8123'
        headers = {'Access-Control-Request-Method': 'GET', 'Access-Control-Request-Headers': 'authorization, content-type'}
        status, fields, _ = self.cors_request('OPTIONS', headers=headers)
        self.assertEqual(status, 200)
        self.assertEqual(fields.get('Access-Control-Allow-Origin'), self.control.allowed_origin)
        self.assertEqual(fields.get('Access-Control-Allow-Methods'), 'GET, POST')
        self.assertEqual(fields.get('Access-Control-Allow-Headers'), 'Authorization, Content-Type')
        self.assertEqual(fields.get('Vary'), 'Origin')
        self.assertIsNone(self.control.admission)
        self.assertIsNone(self.control.accept)
        for changed in [
                {'Access-Control-Request-Method': 'DELETE'},
                {'Access-Control-Request-Headers': 'authorization, x-foreign'},
                {'Access-Control-Request-Headers': '*'}]:
            with self.subTest(changed=changed):
                self.assertEqual(self.cors_request('OPTIONS', headers={**headers, **changed})[0], 403)
        for origin in ['null', 'http://localhost:8123', self.control.allowed_origin + '.foreign', self.control.allowed_origin + '/']:
            with self.subTest(origin=origin):
                status, fields, _ = self.cors_request('OPTIONS', origin=origin, headers=headers)
                self.assertEqual(status, 403)
                self.assertNotIn('Access-Control-Allow-Origin', fields)

    def test_browser_origin_does_not_replace_role_capabilities(self):
        self.assertEqual(self.cors_request('GET', headers={'Authorization': 'Bearer ' + self.control.viewer_token})[0], 403)
        self.control.allowed_origin = 'http://127.0.0.1:8123'
        host = {'Authorization': 'Bearer ' + self.control.host_token}
        viewer = {'Authorization': 'Bearer ' + self.control.viewer_token}
        status, fields, _ = self.cors_request('POST', '/admit', headers=viewer, body=self.admission)
        self.assertEqual(status, 403)
        self.assertEqual(fields.get('Access-Control-Allow-Origin'), self.control.allowed_origin)
        self.assertEqual(self.cors_request('POST', '/admit', origin='http://foreign.example', headers=host, body=self.admission)[0], 403)
        self.assertIsNone(self.control.admission)
        self.assertEqual(self.cors_request('POST', '/admit', headers=host, body=self.admission)[0], 200)
        self.assertEqual(self.cors_request('GET', headers=host)[0], 403)
        self.assertEqual(self.cors_request('GET', headers=viewer)[2], self.admission)
        self.assertEqual(self.cors_request('POST', '/accept', headers=viewer, body=self.accept)[0], 200)
        self.assertEqual(self.request('/take', 'host'), (200, self.accept))
        self.assertEqual(self.request('/admission'), (200, self.admission))

    def test_origin_policy_refuses_nonorigins_and_duplicate_headers(self):
        for origin in ['null', '*', 'file://host', 'http://host/', 'http://host?query', 'http://user@host', 'http://host:wrong', 'http://host/#fragment']:
            with self.subTest(origin=origin), self.assertRaises(ValueError):
                Control(allowed_origin=origin)
        self.control.allowed_origin = 'http://127.0.0.1:8123'
        peer = http.client.HTTPConnection('127.0.0.1', self.control.server.server_port, timeout=3)
        self.addCleanup(peer.close)
        peer.putrequest('GET', '/admission')
        peer.putheader('Authorization', 'Bearer ' + self.control.viewer_token)
        for _ in range(2):
            peer.putheader('Origin', self.control.allowed_origin)
        peer.endheaders()
        response = peer.getresponse()
        self.assertEqual(response.status, 403)
        self.assertIsNone(response.getheader('Access-Control-Allow-Origin'))
        response.read()

    @unittest.skipUnless(os.environ.get('FORTRESS_PLAYWRIGHT_PACKAGE') and os.environ.get('FORTRESS_CHROMIUM_EXECUTABLE'),
                         'explicit browser package and executable required')
    def test_actual_browser_preflight_and_capability_separation(self):
        class Page(BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200)
                self.send_header('Content-Type', 'text/html')
                self.end_headers()
                self.wfile.write(b'<!doctype html><title>Spectator control origin</title>')

            def log_message(self, *_args):
                pass

        servers = [HTTPServer(('127.0.0.1', 0), Page) for _ in range(2)]
        threads = [threading.Thread(target=server.serve_forever, daemon=True) for server in servers]
        for server, thread in zip(servers, threads):
            thread.start()
            self.addCleanup(thread.join, 3)
            self.addCleanup(server.server_close)
            self.addCleanup(server.shutdown)
        origins = ['http://127.0.0.1:' + str(server.server_port) for server in servers]
        self.control.allowed_origin = origins[0]
        program = r"""
const { chromium } = require(process.env.FORTRESS_PLAYWRIGHT_PACKAGE);
const input = JSON.parse(require('fs').readFileSync(0, 'utf8'));
(async () => {
  const browser = await chromium.launch({headless:true, executablePath:process.env.FORTRESS_CHROMIUM_EXECUTABLE, args:['--no-sandbox']});
  try {
    const context = await browser.newContext();
    const page = await context.newPage();
    await page.goto(input.origins[0]);
    const result = await page.evaluate(async (data) => {
      const request = async (path, role, body) => {
        const response = await fetch(data.url + path, {method: body ? 'POST' : 'GET',
          headers:{Authorization:'Bearer ' + data[role], 'Content-Type':'application/json'}, body: body ? JSON.stringify(body) : undefined});
        return {status:response.status, body:await response.json()};
      };
      const expect = (actual, wanted) => {if(actual !== wanted) throw Error('unexpected browser control status');};
      expect((await request('/admission','viewer')).status,404);
      expect((await request('/admit','viewer',data.admission)).status,403);
      expect((await request('/admit','host',data.admission)).status,200);
      expect((await request('/admission','host')).status,403);
      const admitted = await request('/admission','viewer');
      expect(admitted.status,200);
      expect(admitted.body.identity,data.admission.identity);
      expect((await request('/accept','viewer',data.accept)).status,200);
      const taken = await request('/take','host');
      expect(taken.status,200);
      expect(taken.body.packet,data.accept.packet);
      let denied = false;
      try {await fetch(data.url + '/admission',{headers:{Authorization:'Bearer ' + data.viewer,'X-Foreign':'denied'}});} catch (_) {denied=true;}
      expect(denied,true);
      return {allowed:true, capability_separation:true, denied_header:true};
    }, input);
    await page.goto(input.origins[1]);
    result.foreign_origin_denied = await page.evaluate(async (data) => {
      try {await fetch(data.url + '/admission',{headers:{Authorization:'Bearer ' + data.viewer}});return false;} catch (_) {return true;}
    }, input);
    if (!result.foreign_origin_denied) throw Error('foreign browser origin read admission');
    process.stdout.write(JSON.stringify(result));
  } finally {await browser.close();}
})().catch(() => {process.stderr.write('browser control qualification failed');process.exitCode=1;});
"""
        payload = {'origins': origins, 'url': 'http://127.0.0.1:' + str(self.control.server.server_port),
                   'host': self.control.host_token, 'viewer': self.control.viewer_token, 'admission': self.admission, 'accept': self.accept}
        process = subprocess.run(['node', '-e', program], input=json.dumps(payload), capture_output=True, encoding='utf-8', timeout=30)
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(json.loads(process.stdout), {'allowed': True, 'capability_separation': True, 'denied_header': True, 'foreign_origin_denied': True})
        self.assertEqual(self.control.received, 1)
        self.assertEqual(self.control.admission, self.admission)
        self.assertGreaterEqual(self.control.rejected, 4)

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

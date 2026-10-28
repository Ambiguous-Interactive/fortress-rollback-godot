"""Bounded loopback admission fixture for the live spectator witness; not a production auth service."""
import hmac
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import secrets
import socket
import sys
import threading

MAX_BYTES = 4096
REQUEST_SECONDS = 2


class DeadlineServer(HTTPServer):
    def handle_error(self, request, address):
        if not isinstance(sys.exception(), (BrokenPipeError, ConnectionResetError)):
            super().handle_error(request, address)

    def process_request(self, request, address):
        def expire():
            try:
                request.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

        deadline = threading.Timer(REQUEST_SECONDS, expire)
        deadline.daemon = True
        deadline.start()
        try:
            super().process_request(request, address)
        finally:
            deadline.cancel()
            deadline.join(timeout=1)



class Control:
    def __init__(self):
        self.host_token = secrets.token_hex(32)
        self.viewer_token = secrets.token_hex(32)
        self.lock = threading.Lock()
        self.admission = None
        self.accept = None
        self.received = 0
        self.rejected = 0
        self.server = DeadlineServer(('127.0.0.1', 0), self.handler())
        self.server.timeout = 1
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    def start(self):
        self.thread.start()
        return 'http://127.0.0.1:' + str(self.server.server_port)

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)
        if self.thread.is_alive():
            raise ValueError('control fixture did not stop')

    def handler(self):
        state = self

        class Handler(BaseHTTPRequestHandler):
            def setup(self):
                super().setup()
                self.connection.settimeout(2)

            def log_message(self, *_args):
                pass

            def do_POST(self):
                self.dispatch()

            def do_GET(self):
                self.dispatch()

            def dispatch(self):
                role = 'host' if self.path in ['/admit', '/take'] else 'viewer'
                expected = 'Bearer ' + (state.host_token if role == 'host' else state.viewer_token)
                supplied = self.headers.get('Authorization', '')
                if not hmac.compare_digest(supplied.encode('utf-8'), expected.encode('ascii')):
                    self.respond(403, {'error': 'unauthorized'})
                    return
                if self.headers.get('Transfer-Encoding') is not None:
                    self.respond(400, {'error': 'unsupported_encoding'})
                    return
                sizes = self.headers.get_all('Content-Length', [])
                size = sizes[0] if sizes else '0'
                if len(sizes) > 1 or len(size) > len(str(MAX_BYTES)) or not size.isascii() or not size.isdecimal() or int(size) > MAX_BYTES:
                    self.respond(413, {'error': 'too_large'})
                    return
                try:
                    body = json.loads(self.rfile.read(int(size))) if int(size) else {}
                except (UnicodeError, ValueError):
                    self.respond(400, {'error': 'malformed'})
                    return
                with state.lock:
                    code, result = self.apply(body)
                self.respond(code, result)

            def apply(self, body):
                if self.command == 'POST' and self.path == '/admit':
                    required = {'viewer', 'room', 'host', 'identity', 'key', 'digest', 'initial_state', 'players', 'width', 'neutral', 'seed', 'rules'}
                    if (state.admission is not None or not isinstance(body, dict) or set(body) != required
                            or any(type(body[key]) is not str or not body[key] for key in required - {'players', 'width'})
                            or type(body['players']) is not int or body['players'] != 2 or type(body['width']) is not int or body['width'] != 1
                            or any(len(body[key]) != size or any(c not in '0123456789abcdef' for c in body[key])
                                   for key, size in [('identity', 64), ('key', 64), ('digest', 32), ('initial_state', 48), ('neutral', 2)])):
                        return 400, {'error': 'invalid_admission'}
                    state.admission = body.copy()
                    return 200, {'admitted': body['viewer']}
                if self.command == 'GET' and self.path == '/admission':
                    return (200, state.admission.copy()) if state.admission else (404, {'error': 'not_admitted'})
                if self.command == 'POST' and self.path == '/accept':
                    if (not isinstance(body, dict) or set(body) != {'viewer', 'room', 'identity', 'packet'} or state.admission is None
                            or any(body.get(key) != state.admission[key] for key in ['viewer', 'room', 'identity'])
                            or type(body['packet']) is not str or len(body['packet']) != 176
                            or any(c not in '0123456789abcdef' for c in body['packet'])):
                        return 403, {'error': 'wrong_lifetime'}
                    if state.accept is not None and state.accept != body:
                        return 409, {'error': 'occupied'}
                    state.accept = body.copy()
                    state.received += 1
                    return 200, {'accepted': True}
                if self.command == 'GET' and self.path == '/take':
                    if state.accept is None:
                        return 200, {}
                    result = state.accept
                    state.accept = None
                    return 200, result
                return 404, {'error': 'not_found'}

            def respond(self, code, result):
                encoded = json.dumps(result, separators=(',', ':')).encode()
                if code >= 400:
                    state.rejected += 1
                self.send_response(code)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(encoded)))
                self.send_header('Cache-Control', 'no-store')
                self.end_headers()
                self.wfile.write(encoded)

        return Handler

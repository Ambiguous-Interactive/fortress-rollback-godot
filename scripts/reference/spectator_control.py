"""Bounded loopback admission fixture for the live spectator witness; not a production auth service."""
import hmac
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import secrets
import socket
import sys
import threading
from urllib.parse import urlsplit

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
    def __init__(self, allowed_origin=None):
        if allowed_origin is not None:
            parsed = urlsplit(allowed_origin)
            if (not allowed_origin.isascii() or parsed.scheme not in ['http', 'https'] or not parsed.hostname
                    or parsed.username is not None or parsed.password is not None
                    or allowed_origin != parsed.scheme + '://' + parsed.netloc):
                raise ValueError('browser origin must be an exact HTTP(S) origin')
            parsed.port  # Validate a declared port before starting a server.
        self.allowed_origin = allowed_origin
        self.host_token = secrets.token_hex(32)
        self.viewer_token = secrets.token_hex(32)
        self.lock = threading.Lock()
        self.admission = None
        self.accept = None
        self.room = None
        self.viewer = None
        self.done = None
        self.paused = None
        self.accepted_once = False
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

            def allowed_origin(self):
                origins = self.headers.get_all('Origin', [])
                return len(origins) == 1 and state.allowed_origin is not None and origins[0] == state.allowed_origin

            def do_OPTIONS(self):
                methods = self.headers.get_all('Access-Control-Request-Method', [])
                header_values = self.headers.get_all('Access-Control-Request-Headers', [])
                headers = [name.strip().lower() for name in header_values[0].split(',')] if len(header_values) == 1 else []
                if (not self.allowed_origin() or len(methods) != 1 or methods[0] not in ['GET', 'POST']
                        or len(header_values) > 1 or any(name not in ['authorization', 'content-type'] for name in headers)):
                    self.respond(403, {'error': 'browser_request_denied'})
                    return
                self.respond(200, {'preflight': True})

            def dispatch(self):
                if self.headers.get_all('Origin', []) and not self.allowed_origin():
                    self.respond(403, {'error': 'wrong_origin'})
                    return
                host_role = (self.path in ['/admit', '/take'] or (self.path == '/room' and self.command == 'POST')
                             or (self.path in ['/viewer', '/done', '/paused'] and self.command == 'GET'))
                role = 'host' if host_role else 'viewer'
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
                if self.path == '/room':
                    if self.command == 'GET':
                        return (200, state.room.copy()) if state.room else (202, {'pending': True})
                    if state.room is not None:
                        return 409, {'error': 'occupied'}
                    if (not isinstance(body, dict) or set(body) != {'code', 'game'}
                            or any(type(value) is not str or not 1 <= len(value) <= 128 for value in body.values())):
                        return 400, {'error': 'invalid_room'}
                    state.room = body.copy()
                    return 200, {'ready': True}
                if self.path == '/viewer':
                    if self.command == 'GET':
                        return (200, state.viewer.copy()) if state.viewer else (202, {'pending': True})
                    if state.viewer is not None:
                        return 409, {'error': 'occupied'}
                    if (state.room is None or not isinstance(body, dict) or set(body) != {'viewer'}
                            or type(body['viewer']) is not str or not 1 <= len(body['viewer']) <= 128):
                        return 400, {'error': 'invalid_viewer'}
                    state.viewer = body.copy()
                    return 200, {'registered': True}
                if self.path == '/paused':
                    if self.command == 'GET':
                        return (200, state.paused.copy()) if state.paused else (202, {'pending': True})
                    if not state.accepted_once or state.done is not None:
                        return 403, {'error': 'wrong_lifetime'}
                    if (type(body) is not dict or set(body) != {'frame', 'buffered_rows'}
                            or type(body['frame']) is not int or not 8 <= body['frame'] < 48
                            or type(body['buffered_rows']) is not int or not 2 <= body['buffered_rows'] <= 64):
                        return 400, {'error': 'invalid_pause'}
                    if state.paused is not None and state.paused != body:
                        return 409, {'error': 'occupied'}
                    state.paused = body.copy()
                    return 200, {'paused': True}
                if self.path == '/done':
                    if self.command == 'GET':
                        return (200, state.done.copy()) if state.done else (202, {'pending': True})
                    if not state.accepted_once or type(body) is not dict or set(body) != {'complete'} or body['complete'] is not True:
                        return 403, {'error': 'wrong_lifetime'}
                    state.done = body.copy()
                    return 200, {'complete': True}
                if self.command == 'POST' and self.path == '/admit':
                    required = {'viewer', 'room', 'host', 'identity', 'key', 'digest', 'initial_state', 'players', 'width', 'neutral', 'seed', 'rules'}
                    if (state.admission is not None or not isinstance(body, dict) or set(body) != required
                            or (state.viewer is not None and body.get('viewer') != state.viewer['viewer'])
                            or any(type(body[key]) is not str or not body[key] for key in required - {'players', 'width'})
                            or type(body['players']) is not int or body['players'] != 2 or type(body['width']) is not int or body['width'] != 1
                            or any(len(body[key]) != size or any(c not in '0123456789abcdef' for c in body[key])
                                   for key, size in [('identity', 64), ('key', 64), ('digest', 32), ('initial_state', 48), ('neutral', 2)])):
                        return 400, {'error': 'invalid_admission'}
                    state.admission = body.copy()
                    return 200, {'admitted': body['viewer']}
                if self.command == 'GET' and self.path == '/admission':
                    return (200, state.admission.copy()) if state.admission else (202, {'pending': True})
                if self.command == 'POST' and self.path == '/accept':
                    if (not isinstance(body, dict) or set(body) != {'viewer', 'room', 'identity', 'packet'} or state.admission is None
                            or any(body.get(key) != state.admission[key] for key in ['viewer', 'room', 'identity'])
                            or type(body['packet']) is not str or len(body['packet']) != 176
                            or any(c not in '0123456789abcdef' for c in body['packet'])):
                        return 403, {'error': 'wrong_lifetime'}
                    if state.accept is not None and state.accept != body:
                        return 409, {'error': 'occupied'}
                    state.accept = body.copy()
                    state.accepted_once = True
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
                if state.allowed_origin is not None:
                    self.send_header('Vary', 'Origin')
                if self.allowed_origin():
                    self.send_header('Access-Control-Allow-Origin', state.allowed_origin)
                    if self.command == 'OPTIONS' and code == 200:
                        self.send_header('Access-Control-Allow-Methods', 'GET, POST')
                        self.send_header('Access-Control-Allow-Headers', 'Authorization, Content-Type')
                self.end_headers()
                self.wfile.write(encoded)

        return Handler

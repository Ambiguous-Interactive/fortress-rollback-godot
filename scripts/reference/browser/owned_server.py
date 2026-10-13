"""Own signaling process lifetimes; expose bounded restart commands to the browser witness."""
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import subprocess
import threading

from signalfish_live_probe import wait_ready


class OwnedServer:
    def __init__(self, executable, environment, port, log):
        self.executable = executable
        self.environment = environment.copy()
        self.port = port
        self.log = log
        self.process = None
        self.events = []
        self.failure = None
        self.control = None
        self.thread = None
        self.lock = threading.Lock()
        self.binary_hash = hashlib.sha256(executable.read_bytes()).hexdigest()
        self.config_hash = hashlib.sha256(environment['SIGNAL_FISH_CONFIG_JSON'].encode('utf-8')).hexdigest()

    def start(self):
        if self.process is not None and self.process.poll() is None:
            raise ValueError('owned server already running')
        if hashlib.sha256(self.executable.read_bytes()).hexdigest() != self.binary_hash:
            raise ValueError('owned server binary changed before restart')
        self.process = subprocess.Popen([str(self.executable)], env=self.environment, stdout=self.log, stderr=subprocess.STDOUT)
        wait_ready(self.process, self.port)
        if self.process.poll() is not None:
            raise ValueError('owned server exited after readiness')

    def stop(self):
        if self.process is None or self.process.poll() is not None:
            raise ValueError('owned server exited unexpectedly before requested termination')
        pid = self.process.pid
        self.process.kill()
        try:
            code = self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=5)
            raise ValueError('owned server did not exit after SIGKILL')
        if code != -9:
            raise ValueError('owned server termination did not produce SIGKILL exit')
        self.events.append({'kind': 'stop', 'method': 'sigkill', 'pid': pid, 'exit_code': code, 'terminal': self.process.poll() == code})
        self.log.write((json.dumps(self.events[-1]) + '\n').encode('utf-8'))
        self.log.flush()
        return self.events[-1]

    def command(self, kind):
        with self.lock:
            if self.failure is not None:
                raise ValueError('owned server control previously failed')
            expected = 'stop' if len(self.events) % 2 == 0 else 'start'
            if kind != expected:
                raise ValueError('owned server command out of order')
            if kind == 'stop':
                return self.stop()
            old_pid = self.events[-1]['pid']
            self.start()
            event = {'kind': 'start', 'pid': self.process.pid, 'previous_pid': old_pid,
                     'ready': True, 'live': self.process.poll() is None, 'port': self.port,
                     'binary_sha256': self.binary_hash, 'config_sha256': self.config_hash}
            if event['pid'] == old_pid:
                raise ValueError('owned server reused the previous process identity')
            self.events.append(event)
            self.log.write((json.dumps(event) + "\n").encode("utf-8"))
            self.log.flush()
            return event

    def __enter__(self):
        try:
            self.start()
            owner = self

            class Handler(BaseHTTPRequestHandler):
                def do_POST(self):
                    try:
                        if self.path not in ('/stop', '/start') or self.headers.get('Content-Length', '0') != '0':
                            raise ValueError('invalid owned server control request')
                        payload = owner.command(self.path[1:])
                        code = 200
                    except Exception as error:
                        owner.failure = str(error)
                        payload, code = {'failure': owner.failure}, 500
                    raw = json.dumps(payload).encode('utf-8')
                    self.send_response(code)
                    self.send_header('Content-Type', 'application/json')
                    self.send_header('Content-Length', str(len(raw)))
                    self.end_headers()
                    self.wfile.write(raw)

                def log_message(self, *_args):
                    pass

            self.control = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
            self.thread = threading.Thread(target=self.control.serve_forever, daemon=True)
            self.thread.start()
            self.url = f'http://127.0.0.1:{self.control.server_port}'
            return self
        except BaseException:
            self.__exit__(None, None, None)
            raise

    def verify_live(self):
        if self.failure is not None or self.process.poll() is not None:
            raise ValueError('owned signaling server failed during gameplay')

    def __exit__(self, *_args):
        if self.control is not None:
            self.control.shutdown()
            self.control.server_close()
            self.thread.join(timeout=5)
        if self.process is not None and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)

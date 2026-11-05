"""Isolate browser fetch lifetimes using the installed Godot template; not release qualification."""
import hashlib,json,os,platform,subprocess,threading,time,zipfile
from pathlib import Path
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
root=Path.cwd();out=root/'.cache/scratch/session154-fetch-lifecycle'
out.mkdir(parents=True,exist_ok=True)
pins=json.loads((root/'docs/reference/pins.json').read_text())
version=pins['godot']['current_stable']
arch={'aarch64':'arm64','x86_64':'x86_64'}[platform.machine()]
with zipfile.ZipFile(root/f'.cache/reference/godot-data/godot/export_templates/{version}.stable/web_nothreads_release.zip') as package:
    source=package.read('godot.js').decode()
start=source.index('var GodotFetch=');end=source.index(';function _godot_js_fetch_create',start)
engine=source[start:end]+';window.GodotFetch=GodotFetch;'
(out/'fetch.js').write_text(engine)
class Handler(BaseHTTPRequestHandler):
    def log_message(self,*args):pass
    def do_GET(self):
        body=b'<!doctype html><title>Fetch lifecycle</title>'
        self.send_response(200);self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length','0')))
        initial=b'{"accepted":true}'
        suffix=b' '*32768 if self.path.startswith('/held') else b''
        self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(initial)+len(suffix)));self.end_headers()
        try:
            self.wfile.write(initial);self.wfile.flush()
            if suffix:
                time.sleep(.5);self.wfile.write(suffix);self.wfile.flush()
        except (BrokenPipeError,ConnectionResetError):pass
server=ThreadingHTTPServer(('127.0.0.1',0),Handler);thread=threading.Thread(target=server.serve_forever);thread.start()
try:
    environment={**os.environ,'FORTRESS_PLAYWRIGHT_PACKAGE':str(root/'.cache/reference/browser/node_modules/@playwright/test'),
      'FORTRESS_CHROMIUM_EXECUTABLE':str(root/'.cache/reference/verified-browser'/arch/pins['browser']['chromium_executables'][arch])}
    command=['node',str(Path(__file__).with_suffix('.cjs')),f'http://127.0.0.1:{server.server_port}',str(out/'fetch.js')]
    process=subprocess.run(command,env=environment,capture_output=True,text=True,timeout=60)
    (out/'result.log').write_text(process.stdout+process.stderr)
    print(json.dumps({'exit':process.returncode,'engine_fetch_sha256':hashlib.sha256(engine.encode()).hexdigest(),'log':str(out/'result.log')}))
finally:
    server.shutdown();server.server_close();thread.join()

raise SystemExit(process.returncode)

#!/usr/bin/env python3
"""Measure a signed Keel candidate offscreen. Pass the .app path as argument."""
import json
import argparse
import http.server
import os
from pathlib import Path
import selectors
import subprocess
import sys
import tempfile
import time
import threading

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('app', type=Path)
parser.add_argument('--scene', choices=['bundled', 'imported'], default='bundled')
parser.add_argument('--cycles', type=int, default=20)
args = parser.parse_args()
app = args.app.resolve()
binary = app / 'Contents/MacOS/Keel'
if not binary.is_file():
    raise SystemExit('Pass the path to a built Keel.app')
class FixtureHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b'<!doctype html><title>Keel local performance fixture</title><h1>Local page</h1><input aria-label="Draft"><div style="height:4000px">Scroll fixture</div>'
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), FixtureHandler)
threading.Thread(target=server.serve_forever, daemon=True).start()
environment = os.environ.copy()
environment['KEEL_PERFORMANCE_URL'] = f'http://127.0.0.1:{server.server_port}/fixture'
environment['KEEL_PERFORMANCE_SCENE'] = args.scene
environment['KEEL_PERFORMANCE_CYCLES'] = str(min(100, max(1, args.cycles)))
start = time.perf_counter()
records = []
with tempfile.TemporaryFile() as errors:
    process = subprocess.Popen([str(binary), '--performance-probe'], stdout=subprocess.PIPE,
                               stderr=errors, text=True, env=environment)
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    try:
        while selector.get_map():
            if time.perf_counter() - start > 240:
                raise TimeoutError('Performance probe exceeded 240 seconds')
            for key, _ in selector.select(timeout=1):
                line = key.fileobj.readline()
                if not line:
                    selector.unregister(key.fileobj)
                    continue
                try:
                    record = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if record.get('event') == 'home-rendered':
                    record['processLaunchToRenderMilliseconds'] = (time.perf_counter() - start) * 1000
                records.append(record)
        returncode = process.wait(timeout=5)
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        selector.close()
        process.stdout.close()
        server.shutdown()
        server.server_close()

complete = next((row for row in records if row.get('event') == 'complete'), None)
if returncode or complete is None:
    print(json.dumps({'status': 'failed', 'returncode': returncode, 'events': records}, indent=2))
    raise SystemExit(1)

result = {
    'status': 'measured',
    'scope': 'Offscreen Home with disposable storage, stored preferences, isolated scene library and nonpersistent WebKit. '
             'Includes repeated local page/close/Undo cycles. Excludes keyboard usability and WebKit child memory. '
             'Imported scenario uses a generated photo; launch timing and process peak memory include fixture preparation.',
    'bundleBytes': sum(p.stat().st_size for p in app.rglob('*') if p.is_file()),
    'events': records,
}
result['budgets'] = {
    'interactiveHome': {'status': 'not-measured', 'targetMilliseconds': 500,
                        'reason': 'Offscreen rendering does not establish interactive keyboard readiness.'},
    'navigationDispatch': {'status': 'pass' if complete['navigationDispatchMilliseconds'] < 150 else 'fail',
                           'targetMilliseconds': 150},
    'idleCPU': {'status': ('not-measured' if complete['idleSampleSeconds'] < 60 else
                          'pass' if complete['idleCPUPercent'] < 0.5 else 'fail'), 'targetPercent': 0.5},
    'bundle': {'status': 'pass' if result['bundleBytes'] < 25_000_000 else 'fail', 'targetBytes': 25_000_000},
    'wholeBrowserMemory': {'status': 'not-measured',
                           'reason': 'WebKit XPC memory is not attributed; no comparable whole-browser baseline.'},
}
metadata = app / 'Contents/Resources/KeelBuild.json'
if metadata.exists():
    result['build'] = json.loads(metadata.read_text())
print(json.dumps(result, indent=2))

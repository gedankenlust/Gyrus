"""Exercise the shipped runtime against isolated synthetic data, no web fetches."""
import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

parser = argparse.ArgumentParser()
parser.add_argument('backend', type=Path)
args = parser.parse_args()
backend = args.backend.resolve()
with tempfile.TemporaryDirectory(prefix='gyrus-runtime-smoke-') as temporary:
    root = Path(temporary)
    with socket.socket() as available:
        available.bind(('127.0.0.1', 0))
        port = available.getsockname()[1]
    env = dict(os.environ, GYRUS_DATA_DIR=str(root / 'data'), GYRUS_BRAIN_ROOT=str(root / 'brain'),
               GYRUS_API_TOKEN='isolated-smoke-token', PYTHONDONTWRITEBYTECODE='1',
               PLAYWRIGHT_BROWSERS_PATH=str(backend / 'python-runtime/playwright-browsers'))
    python = backend / 'python-runtime/bin/python3'
    def request(path, payload=None, authenticated=True):
        headers = {'Content-Type': 'application/json'}
        if authenticated: headers['X-Gyrus-Token'] = 'isolated-smoke-token'
        body = json.dumps(payload).encode() if payload is not None else None
        req = urllib.request.Request(f'http://127.0.0.1:{port}{path}', data=body, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=5) as response:
                return response.status, json.load(response)
        except urllib.error.HTTPError as error:
            return error.code, json.load(error)
    with (root / 'server.log').open('w+') as log:
        server = subprocess.Popen([str(python), '-m', 'uvicorn', 'main:app', '--host', '127.0.0.1',
                                   '--port', str(port), '--log-level', 'info'], cwd=backend, env=env,
                                  stdout=log, stderr=subprocess.STDOUT)
        try:
            for _ in range(100):
                if server.poll() is not None:
                    log.seek(0)
                    raise RuntimeError(log.read())
                try:
                    status, ready = request('/api/ready')
                    if status == 200: break
                except OSError:
                    time.sleep(0.1)
            else: raise AssertionError('Backend startup timed out')
            assert ready['service'] == 'gyrus'
            assert request('/api/ready', authenticated=False)[0] == 401
            payload = {'version': 2, 'collections': [{'id': 'folder', 'name': 'Keep'}], 'tags': [],
                       'bookmarks': [{'id': 'bookmark', 'title': 'Synthetic', 'url': 'https://example.invalid',
                                      'collection_id': 'folder', 'metadata_status': 'ready', 'reader_status': 'ready'}]}
            status, preview = request('/api/data/restore/preview', payload)
            assert status == 200 and preview['bookmarks'] == 1
            assert request('/api/data/restore', payload)[0] == 200
            assert request('/api/data/restore', {'unrelated': True})[0] == 422
            status, backup = request('/api/data/backup')
            assert status == 200 and backup['bookmarks'][0]['id'] == 'bookmark'
            assert request('/api/data/backup-status')[0] == 200
            assert request('/api/search/status')[1]['available'] is False
        finally:
            server.terminate()
            server.wait(timeout=10)
        log.seek(0)
        assert 'Application shutdown complete.' in log.read()
    # Uvicorn 0.32 re-raises the termination signal after graceful shutdown.
    assert server.returncode in (0, -15), server.returncode
    chromium = subprocess.run([str(python), '-c', '''from playwright.sync_api import sync_playwright
with sync_playwright() as p:
    browser = p.chromium.launch(headless=True)
    page = browser.new_page()
    page.set_content('<h1>Gyrus runtime check</h1>')
    assert page.locator('h1').inner_text() == 'Gyrus runtime check'
    assert len(page.screenshot()) > 100
    print('Chromium', browser.version)
    browser.close()
'''], cwd=backend, env=env, text=True, capture_output=True, timeout=40, check=True)
    print(json.dumps({'ready_auth': 'passed', 'restore_preview': 'passed', 'invalid_restore_preserves_data': 'passed',
                      'portable_backup': 'passed', 'ai_default_off': 'passed', 'graceful_backend_exit': server.returncode,
                      'bundled_browser': chromium.stdout.strip()}, indent=2))

#!/usr/bin/env python3
"""Adapt, validate and exercise stack ingress against two local dummy upstreams."""
import http.server
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
CADDY = os.environ.get('CADDY_BIN') or shutil.which('caddy')
if not CADDY:
    raise SystemExit('CADDY_BIN must point to a local Caddy 2.10+ binary')


def upstream(name):
    seen = []

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            seen.append(self.path)
            body = json.dumps({'upstream': name, 'path': self.path}).encode()
            self.send_response(200)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        do_POST = do_GET

        def log_message(self, *_):
            pass

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server, seen


mcp, mcp_seen = upstream('mcp')
gateway, gateway_seen = upstream('gateway')
try:
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    with tempfile.TemporaryDirectory(prefix='grok-caddy-') as temporary:
        directory = Path(temporary)
        config = directory / 'Caddyfile'
        text = (ROOT / 'caddy/Caddyfile.code-guda-gateway').read_text()
        text = text.replace('{{DOMAIN}}', f'http://127.0.0.1:{port}')
        text = text.replace('{{LISTEN_ADDR}}', f'127.0.0.1:{gateway.server_port}')
        text = text.replace('127.0.0.1:8800', f'127.0.0.1:{mcp.server_port}')
        access_log = directory / 'access.jsonl'
        text = text.replace(' {\n', ' {\n\tlog {\n\t\toutput file ' + str(access_log) + '\n\t\tformat json\n\t}\n', 1)
        config.write_text('{\n admin off\n auto_https off\n}\n' + text)
        subprocess.run([CADDY, 'adapt', '--config', str(config), '--adapter', 'caddyfile', '--validate'], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        with (directory / 'caddy.log').open('w+') as log:
            process = subprocess.Popen([CADDY, 'run', '--config', str(config), '--adapter', 'caddyfile'], stdout=log, stderr=log)
            try:
                base = f'http://127.0.0.1:{port}'
                for _ in range(100):
                    try:
                        urllib.request.urlopen(base + '/health', timeout=.1).close()
                        break
                    except (OSError, urllib.error.URLError):
                        if process.poll() is not None:
                            raise AssertionError('staged Caddy exited')
                        time.sleep(.02)
                else:
                    raise AssertionError('staged Caddy did not become ready')

                def request(path, method='GET'):
                    return urllib.request.urlopen(urllib.request.Request(base + path, method=method), timeout=2)

                for route in ['/auth/cli/start', '/auth/cli/approve', '/auth/cli/callback?code=dummy-sensitive-code&state=dummy-sensitive-state', '/auth/cli/check?authRunId=dummy-public-id', '/mcp', '/api/v1/search', '/api/v1/fetch', '/api/v1/map']:
                    with request(route, 'POST' if route in ['/auth/cli/start', '/api/v1/search', '/api/v1/fetch', '/api/v1/map'] else 'GET') as response:
                        data = json.load(response)
                        assert data == {'upstream': 'mcp', 'path': route}, data
                for route in ['/.well-known/oauth-authorization-server', '/.well-known/oauth-protected-resource/mcp', '/authorize?state=dummy-sensitive-authorize', '/authorize/github/callback?code=dummy-sensitive-github-code&state=dummy-sensitive-github-state', '/register', '/token?code=dummy-sensitive-token', '/admin', '/health?control=ordinary-request', '/grok/v1/models']:
                    with request(route, 'POST' if route.startswith('/token?') else 'GET') as response:
                        assert json.load(response) == {'upstream': 'gateway', 'path': route}
                before = (len(mcp_seen), len(gateway_seen))
                for route in ['/internal', '/internal/keys/verify', '/internal-other', '/auth/cli/unknown']:
                    try:
                        request(route)
                        raise AssertionError('protected route unexpectedly allowed')
                    except urllib.error.HTTPError as error:
                        assert error.code == 404
                assert before == (len(mcp_seen), len(gateway_seen)), 'denied paths reached upstream'
            finally:
                process.terminate()
                process.wait(timeout=5)
            log.seek(0)
            logged = log.read()
            assert 'dummy-sensitive-code' not in logged and 'dummy-sensitive-state' not in logged
        access_text = access_log.read_text()
        access_entries = [json.loads(line) for line in access_text.splitlines()]
        logged_urls = [entry['request']['uri'] for entry in access_entries]
        assert '/health?control=ordinary-request' in logged_urls, 'ordinary control request missing from actual HTTP access log'
        assert '/mcp' in logged_urls, 'MCP control request missing from actual HTTP access log'
        assert not any(url.split('?')[0] in ['/authorize', '/token'] or url.startswith('/authorize/') or url.startswith('/auth/cli/') for url in logged_urls), logged_urls
        assert 'dummy-sensitive-' not in access_text
        print('Caddy adapt/validate and 21 staged route probes passed; actual HTTP access log records controls and skips sensitive URLs.')
finally:
    mcp.shutdown()
    mcp.server_close()
    gateway.shutdown()
    gateway.server_close()

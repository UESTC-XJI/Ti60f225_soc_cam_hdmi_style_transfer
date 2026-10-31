"""Serve the BLE viewer (this directory only) to a phone or another computer.

Same Wi-Fi (no ZeroTier needed) — use this PC's IPv4 address from `ipconfig`:

    python3 tools/ble_web/serve.py --bind 192.168.1.23 --port 8443 --https
    # phone opens https://192.168.1.23:8443/ and accepts the self-signed certificate

Across networks (optional) — with ZeroTier joined, omit --bind:

    python3 tools/ble_web/serve.py --https

Web Bluetooth only works in a secure context. Over plain HTTP the remote Chrome must list
the origin in chrome://flags/#unsafely-treat-insecure-origin-as-secure. With --https the
remote device must trust (or click through) the self-signed certificate instead.
The Bluetooth link itself always runs between the browser's device and the BLE module.

PWA install and the offline service worker need HTTPS (or localhost). For a local test:

    python3 tools/ble_web/serve.py --bind 127.0.0.1 --port 8000
    # then open http://127.0.0.1:8000/ — localhost counts as a secure context
"""
import argparse
import functools
import http.server
import ipaddress
import mimetypes
import os
import shutil
import socket
import ssl
import string
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ICONS = HERE / 'icons'
mimetypes.add_type('application/manifest+json', '.webmanifest')
mimetypes.add_type('text/javascript', '.js')
mimetypes.add_type('image/svg+xml', '.svg')

FILES = {
    '/': 'index.html',
    '/index.html': 'index.html',
    '/index_mobile.html': 'index_mobile.html',
    '/app.css': 'app.css',
    '/app.js': 'app.js',
    '/ble_proto.js': 'ble_proto.js',
    '/sw.js': 'sw.js',
    '/manifest.webmanifest': 'manifest.webmanifest',
    '/manifest-mobile.webmanifest': 'manifest-mobile.webmanifest',
}


def zerotier_address():
    """First IPv4 address on a ZeroTier interface (named zt*)."""
    try:
        out = subprocess.run(['ip', '-4', '-o', 'addr', 'show'], capture_output=True, text=True, check=True).stdout
    except (OSError, subprocess.CalledProcessError):
        return None
    for line in out.splitlines():
        parts = line.split()
        if len(parts) > 3 and parts[1].startswith('zt'):
            return parts[3].split('/')[0]
    return None


class Handler(http.server.SimpleHTTPRequestHandler):
    """Only the viewer files and icons; no directory listings or other paths."""

    @staticmethod
    def resolve(path):
        if path in FILES:
            return FILES[path]
        if path.startswith('/icons/'):
            name = path[len('/icons/'):]
            if name and '/' not in name and '\\' not in name and (ICONS / name).is_file():
                return f'icons/{name}'
        return None

    def do_GET(self):
        path = self.path.split('?', 1)[0]
        target = self.resolve(path)
        if not target:
            self.send_error(404)
            return
        self.path = '/' + target
        super().do_GET()

    def do_HEAD(self):
        self.do_GET()

    def end_headers(self):
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        super().end_headers()

    def list_directory(self, path):
        self.send_error(404)


def find_openssl():
    """Locate openssl even when Python was started from PowerShell/cmd (Git ships one)."""
    found = shutil.which('openssl')
    if found:
        return found
    candidates = []
    git = shutil.which('git')
    if git:
        root = Path(git).resolve().parent.parent
        candidates += [root / 'mingw64/bin/openssl.exe', root / 'usr/bin/openssl.exe']
    for base in (os.environ.get('ProgramFiles'), os.environ.get('ProgramFiles(x86)'),
                 os.environ.get('LOCALAPPDATA')):
        if base:
            folder = Path(base)
            candidates += [
                folder / 'Git/mingw64/bin/openssl.exe',
                folder / 'Git/usr/bin/openssl.exe',
                folder / 'Programs/Git/mingw64/bin/openssl.exe',
                folder / 'Programs/Git/usr/bin/openssl.exe',
            ]
    # Portable/custom Git installs (e.g. E:\Git) are not on PATH and may live on any drive.
    for drive in string.ascii_uppercase:
        candidates += [Path(f'{drive}:/Git/mingw64/bin/openssl.exe'),
                       Path(f'{drive}:/Git/usr/bin/openssl.exe')]
    for path in candidates:
        if path.is_file():
            return str(path)
    return None


def certificate(address):
    """Self-signed certificate for this address, kept in tools/ble_web/cert/ (git-ignored)."""
    folder = HERE / 'cert'
    folder.mkdir(exist_ok=True)
    (folder / '.gitignore').write_text('*\n')
    crt, key = folder / f'{address}.crt', folder / f'{address}.key'
    if not crt.exists() or not key.exists():
        openssl = find_openssl()
        if not openssl:
            sys.exit('openssl not found. Install Git for Windows (it includes openssl), '
                     'or run without --https and allow HTTP in Chrome flags.')
        try:
            ipaddress.ip_address(address)
            san = f'IP:{address}'
        except ValueError:
            san = f'DNS:{address}'
        try:
            subprocess.run([openssl, 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '825',
                            '-subj', f'/CN={address}', '-addext', f'subjectAltName={san}',
                            '-keyout', str(key), '-out', str(crt)], check=True, capture_output=True)
        except subprocess.CalledProcessError as e:
            detail = (e.stderr or b'').decode('utf-8', 'replace').strip()
            sys.exit(f'openssl failed to create {crt.name}:\n{detail}')
        key.chmod(0o600)
    return crt, key


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--bind', help='address to listen on (default: the ZeroTier address)')
    ap.add_argument('--port', type=int, default=8443)
    ap.add_argument('--https', action='store_true', help='serve HTTPS with a self-signed certificate')
    a = ap.parse_args()

    bind = a.bind or zerotier_address()
    if not bind:
        sys.exit('No --bind address and no ZeroTier interface found.\n'
                 'Phone on the same Wi-Fi: pass this PC\'s IPv4 (see `ipconfig`):\n'
                 '    python tools/ble_web/serve.py --bind <PC IPv4> --port 8443 --https\n'
                 'ZeroTier is optional and only needed when the two devices are on different networks.')
    server = http.server.ThreadingHTTPServer((bind, a.port), functools.partial(Handler, directory=str(HERE)))
    scheme = 'http'
    if a.https:
        host = bind if bind != '0.0.0.0' else (zerotier_address() or socket.gethostname())
        crt, key = certificate(host)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(crt, key)
        server.socket = ctx.wrap_socket(server.socket, server_side=True)
        scheme = 'https'
        print(f'Certificate: {crt}')
    shown = bind if bind != '0.0.0.0' else (zerotier_address() or bind)
    print(f'Serving {HERE} at {scheme}://{shown}:{a.port}/   (Ctrl+C to stop)')
    if scheme == 'http':
        print(f'Remote Chrome: add {scheme}://{shown}:{a.port} to chrome://flags/#unsafely-treat-insecure-origin-as-secure')
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == '__main__':
    main()

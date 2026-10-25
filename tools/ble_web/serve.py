"""Serve the BLE image viewer (this directory only) to other devices, e.g. over ZeroTier.

    python3 tools/ble_web/serve.py                 # HTTP on the ZeroTier address, port 8443
    python3 tools/ble_web/serve.py --https         # HTTPS, self-signed certificate for that address
    python3 tools/ble_web/serve.py --bind 0.0.0.0  # every interface (not recommended)

Web Bluetooth only works in a secure context. Over plain HTTP the remote Chrome must list
the origin in chrome://flags/#unsafely-treat-insecure-origin-as-secure. With --https the
remote device must trust (or click through) the self-signed certificate instead.
The Bluetooth link itself always runs between the browser's device and the BLE module.
"""
import argparse
import functools
import http.server
import ipaddress
import socket
import ssl
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
FILES = {'/': 'index.html', '/index.html': 'index.html', '/ble_proto.js': 'ble_proto.js'}


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
    """Only the viewer files; no directory listings or other paths."""

    def do_GET(self):
        path = self.path.split('?', 1)[0]
        if path not in FILES:
            self.send_error(404)
            return
        self.path = '/' + FILES[path]
        super().do_GET()

    def do_HEAD(self):
        self.do_GET()

    def end_headers(self):
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        super().end_headers()

    def list_directory(self, path):
        self.send_error(404)


def certificate(address):
    """Self-signed certificate for this address, kept in tools/ble_web/cert/ (git-ignored)."""
    folder = HERE / 'cert'
    folder.mkdir(exist_ok=True)
    (folder / '.gitignore').write_text('*\n')
    crt, key = folder / f'{address}.crt', folder / f'{address}.key'
    if not crt.exists() or not key.exists():
        try:
            ipaddress.ip_address(address)
            san = f'IP:{address}'
        except ValueError:
            san = f'DNS:{address}'
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '825',
                        '-subj', f'/CN={address}', '-addext', f'subjectAltName={san}',
                        '-keyout', str(key), '-out', str(crt)], check=True, capture_output=True)
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
        sys.exit('No ZeroTier (zt*) IPv4 address found; is zerotier-one joined? Use --bind to choose one.')
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

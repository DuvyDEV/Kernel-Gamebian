#!/usr/bin/env python3
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from pathlib import Path
import mimetypes, os

REPO_DIR = Path("/var/www/debian-redroot")
HOST = "0.0.0.0"
PORT = 8000

# Tipos útiles para APT
mimetypes.add_type("application/vnd.debian.binary-package", ".deb")
mimetypes.add_type("application/gzip", ".gz")
mimetypes.add_type("application/pgp-signature", ".gpg")
mimetypes.add_type("text/plain", ".InRelease")
mimetypes.add_type("text/plain", ".Release")

ALLOWED_PREFIXES = ("/dists/", "/pool/")
ALLOWED_FILES = ("/KEY.asc", "/apt-ftparchive.conf", "/")

class RepoHandler(SimpleHTTPRequestHandler):
    # Minimiza banner del servidor
    server_version = "APT-Repo/1.0"
    sys_version = ""

    def do_GET(self):
        if not self._is_allowed(self.path):
            self.send_error(403, "Forbidden")
            return
        super().do_GET()

    def do_HEAD(self):
        if not self._is_allowed(self.path):
            self.send_error(403, "Forbidden")
            return
        super().do_HEAD()

    # Bloquea métodos no usados
    def do_POST(self): self.send_error(405, "Method Not Allowed")
    def do_PUT(self):  self.send_error(405, "Method Not Allowed")
    def do_DELETE(self): self.send_error(405, "Method Not Allowed")
    def do_PATCH(self): self.send_error(405, "Method Not Allowed")
    def do_OPTIONS(self): self.send_error(405, "Method Not Allowed")

    def _is_allowed(self, path: str) -> bool:
        # normaliza query/fragment
        p = path.split('?',1)[0].split('#',1)[0]
        return p in ALLOWED_FILES or any(p.startswith(pref) for pref in ALLOWED_PREFIXES)

    def translate_path(self, path):
        # Limitar estrictamente a REPO_DIR y evitar traversal
        root = os.fspath(REPO_DIR)
        path = path.split('?',1)[0].split('#',1)[0]
        parts = [p for p in path.split('/') if p and p not in ('.', '..')]
        return os.path.join(root, *parts)

    # Deshabilita listados de directorio (403)
    def list_directory(self, path):
        self.send_error(403, "Directory listing disabled")
        return None

    def end_headers(self):
        # Seguridad básica
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Permissions-Policy", "geolocation=(), microphone=(), camera=()")
        self.send_header("X-Frame-Options", "DENY")

        # Cache: índices cambian; pool es inmutable
        p = self.path.split('?',1)[0].split('#',1)[0]
        if p.startswith("/pool/"):
            # artefactos .deb y .sha256: cache largo
            self.send_header("Cache-Control", "public, max-age=31536000, immutable")
        else:
            # índices y metadatos: cache corto
            self.send_header("Cache-Control", "public, max-age=300")
        super().end_headers()

if __name__ == "__main__":
    os.chdir(REPO_DIR)
    httpd = ThreadingHTTPServer((HOST, PORT), RepoHandler)
    print(f"Serving APT repo on http://{HOST}:{PORT}/")
    httpd.serve_forever()


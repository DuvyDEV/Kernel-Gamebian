#!/usr/bin/env python3
import threading, time, os
from update_repo import run_daemon
from server import RepoHandler, HOST, PORT, REPO_DIR
from http.server import ThreadingHTTPServer

def start_server():
    os.chdir(REPO_DIR)
    httpd = ThreadingHTTPServer((HOST, PORT), RepoHandler)
    httpd.serve_forever()

if __name__ == "__main__":
    t = threading.Thread(target=run_daemon, daemon=True)
    t.start()
    time.sleep(2)  # deja crear estructura/clave
    start_server()


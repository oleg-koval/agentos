#!/usr/bin/env python3
"""A failed live fetch must never authorize replacing stable with beta."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import subprocess
import tempfile
from threading import Thread

repo = Path(__file__).resolve().parents[1]


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(self.server.response_status)
        self.end_headers()

    def log_message(self, *args):
        pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
thread = Thread(target=server.serve_forever, daemon=True)
thread.start()
try:
    with tempfile.TemporaryDirectory() as temporary:
        for status in (503, 429, 403, 200, 404):
            server.response_status = status
            for kind in ("root", "channel"):
                destination = Path(temporary) / f"{kind}-{status}"
                command = ["bash", str(repo / f"release/fetch-live-{kind}.sh"),
                           f"http://127.0.0.1:{server.server_port}"]
                if kind == "channel":
                    command.append("stable")
                command.append(str(destination))
                result = subprocess.run(command, capture_output=True, timeout=10)
                assert (result.returncode == 0) == (status == 404), (kind, status, result.stderr)
                if status != 404:
                    assert b"refusing publication" in result.stderr, result.stderr
finally:
    server.shutdown()
    server.server_close()
    thread.join()
print("Publication refuses server errors, denied/rate-limited requests, and empty responses.")

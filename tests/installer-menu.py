#!/usr/bin/env python3
"""Exercise the actual erase menu in a PTY without running disk operations."""
import os
from pathlib import Path
import pty
import select
import subprocess
import time

source = (Path(__file__).resolve().parents[1] / "install.sh").read_text()


def function(name):
    start = source.index(name + "() {")
    return source[start:source.index("\n}", start) + 2]


script = "set -euo pipefail\n" + function("pick_option") + "\n" + function("confirm")
script += '\nDISK=/dev/test-only\nconfirm\nprintf "ERASE_APPROVED\\n"\n'
for keys, expected in ((b"\n", 1), (b"\x1b[B\n", 0)):
    master, slave = pty.openpty()
    process = subprocess.Popen(["bash", "-c", script], stdin=slave, stdout=slave, stderr=slave)
    os.close(slave)
    output = b""
    deadline = time.monotonic() + 5
    sent = False
    try:
        while time.monotonic() < deadline:
            if select.select([master], [], [], 0.1)[0]:
                try:
                    output += os.read(master, 65536)
                except OSError:
                    break
            if not sent and b"Use arrow keys and Enter." in output:
                os.write(master, keys)
                sent = True
        assert process.wait(timeout=1) == expected, output
        assert (b"ERASE_APPROVED" in output) == (expected == 0), output
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        os.close(master)
print("Installer erase defaults to Cancel; explicit selection succeeds (no disk access).")

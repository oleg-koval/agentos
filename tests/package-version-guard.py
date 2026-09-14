#!/usr/bin/env python3
"""Check package-version enforcement in a disposable Git repository, offline."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


repo = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="agentos-version-guard-") as temporary:
    root = Path(temporary)
    (root / "tests").mkdir()
    (root / "packages/agentos-runtime").mkdir(parents=True)
    (root / "packages/agentos-shell").mkdir(parents=True)
    shutil.copyfile(repo / "tests/package-version.sh", root / "tests/package-version.sh")
    package = root / "packages/agentos-runtime/PKGBUILD"
    package.write_text("pkgver=1.0.0\npkgrel=2\n")
    shell_package = root / "packages/agentos-shell/PKGBUILD"
    shell_package.write_text("pkgver=1.0.0\npkgrel=2\n")
    manifest = root / "stable.json"
    manifest.write_text(json.dumps({"packages": [
        {"name": "agentos-runtime-1.0.0-1-x86_64.pkg.tar.zst"},
        {"name": "agentos-shell-1.0.0-1-x86_64.pkg.tar.zst"},
    ]}))

    def git(*args):
        return subprocess.check_output([
            "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
            "-c", "core.hooksPath=/dev/null", *args,
        ], cwd=root, stderr=subprocess.DEVNULL, text=True).strip()

    def check(base, expected, message=""):
        result = subprocess.run(["bash", "tests/package-version.sh"], cwd=root,
                                env={**os.environ, "AGENTOS_LIVE_RELEASE_MANIFEST": str(manifest),
                                     "AGENTOS_VERSION_BASE_REF": base},
                                capture_output=True, text=True)
        assert result.returncode == expected, (base, result.stdout, result.stderr)
        assert message in result.stderr, result.stderr

    git("init", "-q")
    git("add", ".")
    git("commit", "-qm", "fixture baseline")
    check("missing-base", 1, "comparison base is unavailable")
    # Literal package inputs plus representatives of its dynamic directory inputs.
    inputs = set(re.findall(r'\$src/([^"$\s]+)',
                           (repo / "packages/agentos-runtime/PKGBUILD").read_text()))
    inputs = {path for path in inputs if not path.endswith("/") and path != "core"}
    inputs.update({"core/go.mod", "systemd/system/test.service", ".agents/skills/test/SKILL.md",
                   "migrations/system/test.sh", "migrations/user/test.sh"})
    for path in sorted(inputs):
        base = git("rev-parse", "HEAD")
        target = root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text("changed package input\n")
        git("add", path)
        git("commit", "-qm", "change packaged input")
        try:
            check(base, 1, "runtime inputs changed without advancing")
        except AssertionError as error:
            raise AssertionError(f"runtime input was not guarded: {path}") from error
    base = git("rev-parse", "HEAD")
    (root / "agentos-home.sh").write_text("shell package only\n")
    git("add", "agentos-home.sh")
    git("commit", "-qm", "change shell input")
    check(base, 1, "shell inputs changed without advancing")
    shell_package.write_text("pkgver=1.0.0\npkgrel=3\n")
    git("add", "packages/agentos-shell/PKGBUILD")
    git("commit", "-qm", "advance shell version")
    check(base, 0)
    base = git("rev-parse", "HEAD")
    package.write_text("pkgver=1.0.0\npkgrel=3\n")
    (root / "workstation-doctor.sh").write_text("another runtime change\n")
    git("add", ".")
    git("commit", "-qm", "advance runtime version")
    check(base, 0)

print("Package-version guard behavior passed.")

#!/usr/bin/env python3
"""Check signed ISO and installed channel versions without modifying the host."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
builder = (repo / "build-agentos-iso.sh").read_text()
version_script = builder[builder.index('manifest_version='):builder.index('# Brand the ISO')]
policy = (repo / "apply-system-policy.sh").read_text()
policy_script = policy[policy.index('[[ -f /etc/agentos/channel ]]'):policy.index('chmod 644 /etc/agentos/channel')]

with tempfile.TemporaryDirectory(prefix="agentos-installer-version-") as temporary:
    root = Path(temporary)
    signed = root / "signed"
    signed.mkdir()
    source = root / "source"
    release = source / "release"
    (release / "channels").mkdir(parents=True)
    host = root / "host"
    host.mkdir()
    for channel, version in (("stable", "1.0"), ("beta", "2.0"), ("edge", "3.0")):
        (release / "channels" / f"{channel}.json").write_text(json.dumps({"version": version}))
    env = {**os.environ, "source_dir": str(root), "signed_repo_dir": str(signed),
           "SOURCE_DIR": str(source)}

    def run(script, **values):
        return subprocess.run(["bash", "-euo", "pipefail", "-c", script],
                              env={**env, **values}, capture_output=True, text=True)

    for signed_version, override, success in (("2.1", "", True), ("2.1", "2.1", True),
                                               ("2.1", "1.0", False), ("../bad", "", False)):
        (signed / "release-manifest.json").write_text(json.dumps({"version": signed_version}))
        result = run(version_script, version=override)
        assert (result.returncode == 0) == success, result.stderr
        if success:
            assert (release / "installer-version").read_text().strip() == signed_version

    (host / "channel").write_text("stable\n")
    policy_script = policy_script.replace("/etc/agentos", str(host))
    result = run(policy_script, AGENTOS_CHANNEL="beta")
    assert result.returncode == 0, result.stderr
    assert (host / "version").read_text().strip() == "2.1"
    (release / "installer-version").unlink()
    for channel, expected in (("stable", "1.0"), ("beta", "2.0"), ("edge", "3.0"), ("none", "dev")):
        result = run(policy_script, AGENTOS_CHANNEL=channel)
        assert result.returncode == 0, result.stderr
        assert (host / "version").read_text().strip() == expected
    assert run(policy_script, AGENTOS_CHANNEL="invalid").returncode != 0

print("ISO versions follow signed manifests; installed versions follow the selected release.")

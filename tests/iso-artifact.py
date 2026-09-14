#!/usr/bin/env python3
"""Exercise the workflow's checksum paths without building or signing an ISO."""
import os
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace

import yaml


repo = Path(__file__).resolve().parents[1]
workflow = yaml.safe_load((repo / ".github/workflows/release.yml").read_text())
steps = {step.get("name"): step for step in workflow["jobs"]["build-iso"]["steps"]}

def eligible(job, event, channel="edge", build_iso=False, ref="refs/heads/main", result="success"):
    expression = workflow["jobs"][job]["if"].removeprefix("${{").removesuffix("}}")
    expression = expression.replace("&&", " and ").replace("||", " or ")
    return eval(expression, {"__builtins__": {}}, {
        "true": True,
        "github": SimpleNamespace(event_name=event, ref=ref),
        "always": lambda: True,
        "needs": SimpleNamespace(verify=SimpleNamespace(result=result), promote=SimpleNamespace(result=result)),
        "inputs": SimpleNamespace(channel=channel, build_iso=build_iso),
    })

for channel in ("edge", "beta", "stable"):
    assert eligible("build-iso", "workflow_dispatch", channel, True) == (channel in ("edge", "beta"))
    assert eligible("build-edge", "workflow_dispatch", channel, True) == (channel == "edge")
    assert eligible("promote", "workflow_dispatch", channel, True) == (channel == "beta")
    assert eligible("build-edge", "workflow_dispatch", channel) == (channel == "edge")
    assert eligible("promote", "workflow_dispatch", channel) == (channel != "edge")
assert not eligible("promote", "schedule")
assert not eligible("promote", "workflow_dispatch", "beta", ref="refs/heads/topic")
assert not eligible("build-iso", "workflow_dispatch", "beta", True, result="failure")
assert eligible("build-edge", "push")

source_check = steps["Validate ISO source selection"]["run"]
for channel, source_run, status in (("edge", "", 0), ("beta", "", 1),
                                    ("stable", "", 1), ("edge", "123", 1), ("beta", "123", 0),
                                    ("beta", "0", 1), ("beta", "invalid", 1)):
    result = subprocess.run(["bash", "-euo", "pipefail", "-c", source_check],
                            env={**os.environ, "CHANNEL": channel, "SOURCE_RUN_ID": source_run},
                            capture_output=True)
    assert result.returncode == status, (channel, source_run, result.stderr)

with tempfile.TemporaryDirectory(prefix="agentos-iso-artifact-") as temporary:
    root = Path(temporary)
    (root / "out/iso").mkdir(parents=True)
    (root / "out/iso/agentos-0.1.0-test.iso").write_bytes(b"ISO checksum fixture\n")
    (root / "release/channels").mkdir(parents=True)
    (root / "release/channels/edge.json").write_text('{"version":"stale-channel-version"}\n')
    (root / "iso-repo/x86_64").mkdir(parents=True)
    (root / "iso-repo/x86_64/release-manifest.json").write_text('{"version":"0.1.0"}\n')
    (root / "release/agentos-signing.asc").touch()
    (root / "bin").mkdir()
    gpg = root / "bin/gpg"
    gpg.write_text("#!/bin/sh\ncat >/dev/null\nexit 0\n")
    gpg.chmod(0o755)
    env = {
        **os.environ,
        "PATH": f"{root / 'bin'}:{os.environ['PATH']}",
        "RUNNER_TEMP": str(root),
        "AGENTOS_GPG_PRIVATE_KEY": "test fixture only",
        "AGENTOS_GPG_KEY_ID": "test fixture only",
    }
    for name in ("Sign and describe ISO artifact", "Verify ISO checksum and signature"):
        script = steps[name]["run"].replace("${{ inputs.channel }}", "edge")
        script = script.replace("${{ env.ISO_SOURCE_COMMIT }}", "fixture-commit")
        subprocess.run(["bash", "-euo", "pipefail", "-c", script], cwd=root,
                       env=env, stdin=subprocess.DEVNULL, check=True)
    # The checksum must also work when a user extracts the artifact elsewhere.
    subprocess.run(["sha256sum", "-c", "agentos-0.1.0-test.iso.sha256"],
                   cwd=root / "out/iso", check=True)

print("ISO artifact checksum workflow passed (GPG mocked).")

# VPS provider validation matrix

The AgentOS bootstrap is provider-neutral: it expects an already-provisioned
Arch Linux x86_64 host with systemd as PID 1, working pacman repositories, an
active SSH listener on TCP 22, and an existing non-root user. Provider
automation must preserve those invariants and must not make the bootstrap
responsible for disk partitioning, firewall policy, or SSH enrollment.

## Current evidence

| Provider/profile | State | Evidence |
| --- | --- | --- |
| Google Cloud, Arch x86_64, disposable VM | Validated | Clean install, onboarding, reset, declarative plan/apply, API, SSH and service checks passed; VM deleted afterward. |
| AWS Arch x86_64 | Pending | Provider credentials were unavailable during the validation window. |
| Hetzner Arch x86_64 | Pending | No disposable test host was provisioned. |

The local provider contract is covered by `tests/vps-install.sh`: dry-run is
non-mutating, apply preserves one managed repository Include, a repeated apply
does not duplicate it, reset restores the saved configuration, and inactive
SSH prevents mutation. The live matrix remains incomplete until another
provider host is available.

## Required evidence for a new provider

1. Record the provider, region/zone, image, architecture, and temporary host
   identity without storing credentials in the repository.
2. Verify SSH access and the provider console recovery path before bootstrap.
3. Run the hosted signed bootstrap dry-run, then apply it with the published
   fingerprint.
4. Run onboarding, declarative plan/apply twice, and reset/recovery checks.
5. Verify the AgentOS API, signed repository, SSH, and selected Tailscale/KRDP
   invariants.
6. Delete the disposable host and confirm no test resources remain.

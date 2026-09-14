# Contributing

Open a focused issue describing expected behavior, actual behavior, version,
host role, and reproduction steps. Use the repository's bug/support templates.
Review `agentos support` output before sharing it; never attach credentials,
private prompts, or unredacted personal data.

Use a branch and a small pull request with the problem, resulting behavior,
and verification. Follow AGENTS.md. Run `bash tests/static.sh` and affected
checks; `.github/workflows/ci.yml` is the full validation contract. Runtime
payload changes require a package revision bump. Boot, input, and display
claims need VM/device evidence in addition to source tests.

Keep LICENSE and relevant third-party notices. Do not commit generated
packages, ISO files, local screenshots, caches, or operator logs.

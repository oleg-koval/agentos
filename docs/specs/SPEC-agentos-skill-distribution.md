# Spec: `agentos-skill-distribution`

## Objective

Make the approved AgentOS skills discoverable on the installed Linux
workstation and in this repository for Codex, Claude Code, and Hermes. Keep one
canonical copy, preserve user-owned skills, and make installation and removal
idempotent and auditable.

## Tech Stack

- Agent Skills `SKILL.md` open format
- `agentos-runtime` package build and manifest
- `install-agent-tools.sh` for user-scoped integrations
- Codex `.agents/skills` discovery and symlink support
- Claude Code `.claude/skills` discovery and symlink support
- Hermes `~/.hermes/skills` discovery and optional external directories

## Commands

The implementation must expose and test a clear, non-destructive install
surface. The existing package/install commands remain the entry points:

```bash
install-agent-tools --update
pacman -Qkk agentos-runtime
find /usr/share/agentos/skills -name SKILL.md -print
find "$HOME/.agents/skills" "$HOME/.claude/skills" -name SKILL.md -print
hermes skills list
```

If a dedicated sync subcommand is needed, define it in the implementation
plan before adding it; do not hide skill installation inside an unrelated
runtime action.

## Project Structure

```text
.agents/skills/                         # Canonical repo source
├── agentos-operator/SKILL.md
└── agentos-maintainer/SKILL.md
packages/agentos-runtime/PKGBUILD       # Installs canonical copies
install-agent-tools.sh                  # User-scoped adapters
tests/skills/                            # Layout, idempotence, and discovery tests
docs/specs/SPEC-agentos-skill-distribution.md
```

The package-owned destination is `/usr/share/agentos/skills`. User adapters
link to that read-only tree from `~/.agents/skills`, `~/.claude/skills`, and
`~/.hermes/skills`; they must never copy stale divergent content over an
existing user skill.

## Code Style

Use one canonical source and explicit adapter ownership:

```bash
install -Dm644 "$src/.agents/skills/agentos-operator/SKILL.md" \
  "$pkgdir/usr/share/agentos/skills/agentos-operator/SKILL.md"
```

Adapters must check whether a target exists, preserve unrelated files, create
directories with existing tool conventions, and report `created`, `updated`,
`preserved`, or `skipped` outcomes. Never use broad recursive deletion.

## Testing Strategy

1. Validate both canonical skill folders with the skill validator.
2. Build the runtime package and inspect its archive for exactly the expected
   skill files and modes.
3. Run the installer twice in a temporary user home and prove idempotence,
   preservation of unrelated skills, and stable symlink targets.
4. Verify Codex and Claude discovery from the repository and user locations.
5. Verify Hermes discovery through its user skill directory while the
   package-owned target is not writable by the agent user.
6. Run existing shell/static/package checks and `git diff --check`.

## Boundaries

- Always: keep canonical source under version control; install root-owned
  copies read-only; preserve user customization; show provenance and version.
- Ask first: changing agent config files, adding a machine-wide admin skill,
  enabling a plugin, or changing package ownership/layout.
- Never: overwrite user skills, make `/usr/share/agentos/skills` writable by an
  agent, duplicate divergent copies, or silently enable privileged tools.

## Success Criteria

- A fresh package install contains both approved skills under
  `/usr/share/agentos/skills`.
- Codex, Claude Code, and Hermes can discover the same `SKILL.md` content from
  their supported locations.
- Re-running `install-agent-tools --update` is idempotent and preserves
  unrelated user skills and configuration.
- A package upgrade updates only AgentOS-owned skill targets and reports any
  user conflict without overwriting it.
- Archive, installer, discovery, permission, static, and live checks pass.

## Open Questions

- Decide whether a future plugin package is needed for non-local/cloud agent
  surfaces. It is out of scope for the first workstation distribution slice.

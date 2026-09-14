# Spec: `versioned-migrations`

## Objective

Add an ordered migration runner for trusted package-owned state changes that
pacman cannot safely express. System migrations may run in the guarded update
transaction; user migrations remain pending until launched visibly for that
user. A failed migration remains pending and stops later migrations.

## Tech stack

- Go 1.23 runner inside `agentos-ops`
- Package-owned migration definitions under `/usr/share/agentos/migrations/`
- System state under `/var/lib/agentos/migrations/`
- Per-user state under `$XDG_STATE_HOME/agentos/migrations/`

The strict ordering and idempotency model is informed by:
https://github.com/omacom/omarchy/blob/quattro/agents/skills/migrations.md

## Commands

```bash
cd core && go test ./cmd/agentos-ops -run Migration
bash tests/migration.sh
bash tests/package-install-migration.sh out/repo/x86_64
bash tests/update-gate.sh
git diff --check
```

## Project structure

- `core/cmd/agentos-ops/` contains migration discovery, validation, locking,
  execution, and status.
- `migrations/system/` and `migrations/user/` contain ordered package inputs.
- `packages/agentos-runtime/PKGBUILD` installs immutable migration definitions.
- Existing package install hooks retain package-layout bootstrapping; future
  state transitions use the runner.

## Code style

Migration IDs are immutable, sortable, and descriptive:

```text
20260906-001-reconcile-native-shell-default
```

Each migration is idempotent, noninteractive, and narrowly matches legacy
state before changing it. Completion is written only after a zero exit status.

## Testing strategy

- Run each migration against temporary system/user roots.
- Run it twice to prove idempotence and against unrelated customized state to
  prove preservation.
- Test locking, invalid IDs, partial completion, stop-on-failure, resume, and
  system/user scope separation.
- Test an update failure stages the existing recovery snapshot.

## Boundaries

- Always: execute only package-owned definitions; serialize runners; log ID,
  scope, timestamps, and bounded error text; stop on first failure.
- Ask first: migrate user-authored configuration, require interactivity, or
  remove an existing package hook.
- Never: mark failed/skipped migrations complete, silently run user migrations
  at login, delete broad paths, or continue after an ordering failure.

## Success criteria

- `agentos migrate status --json` distinguishes applied, pending, and failed
  migrations for system and current-user scopes.
- `agentos migrate apply --scope system|user` applies only the selected scope.
- The guarded update runs pending system migrations and treats failure as an
  update failure eligible for existing rollback staging.
- Pending user migrations appear as an attention item and open a visible action.
- Existing legacy cleanup and unrelated administrator files remain intact.

## Package-hook inventory

The initial inventory is resolved as follows:

- Package bootstrapping retains exact legacy path cleanup needed to prevent
  `/usr/local` binaries and `/etc` units from shadowing package-owned files.
- Repository/config convergence, unit enablement, power-policy convergence,
  and active user-manager reload remain idempotent install/upgrade hooks.
- Removal of the old unmanaged wallpaper and clearing the legacy health-unit
  failure become ordered system migrations.
- Removal of copied per-user AgentOS units and the old per-user KWin script
  becomes an explicit user migration; package hooks no longer mutate `$HOME`.

This keeps pacman ownership safe while ensuring one-time state transitions are
visible, durable, and resumable.

## Adoption boundary

The updater process that starts a package transaction continues running its
pre-update executable. Therefore, the first upgrade from a release that predates
the migration runner installs the definitions but does not execute the new
post-pacman migration step in that same process. The migrations remain pending
and run on the next guarded update or explicit `agentos migrate apply`. Running
them from a pacman hook is intentionally avoided because hook failures occur
inside the package transaction and cannot use the updater's snapshot-staging
failure path.

# Project layout

This workstation uses a deliberately boring, shallow Unix source tree. It is inspired by the kind of
low-ceremony layout you would expect from an experienced kernel developer, not a claim about Linus
Torvalds' exact personal directory names.

```text
~/src/          canonical Git clones
~/worktrees/    parallel branches and agent worktrees
~/scratch/      disposable experiments and one-off reproductions
~/build/        generated/out-of-tree build output
```

## Rules

1. Put the authoritative checkout directly under `~/src`:

   ```text
   ~/src/agentos
   ~/src/promptctl
   ~/src/linux
   ```

2. Do not create hierarchy for language, employer, Git host, or "personal vs work" unless there is an
   actual naming collision. Repository names already provide the useful namespace most of the time.

3. Keep temporary branches and AI-agent worktrees out of the canonical clone. Use `~/worktrees`.
   Herdr's default `~/.herdr/worktrees` path is linked there by `setup-project-layout`.

4. `~/scratch` is disposable. Nothing important should exist only there.

5. `~/build` is generated output. Source code belongs in `~/src`; build artifacts do not.

6. Do not put source repositories in `~/Downloads`, `~/Desktop`, or random home-directory folders.

## Shell shortcuts

```text
csrc       cd ~/src
cwt        cd ~/worktrees
cscratch   cd ~/scratch
cbuild     cd ~/build
```

`sync-workstation` creates the layout idempotently. It does not move existing repositories automatically;
that should be deliberate so paths used by scripts, IDEs, and credentials are not silently broken.

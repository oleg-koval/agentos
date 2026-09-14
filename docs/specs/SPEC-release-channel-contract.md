# Spec: `release-channel-contract`

## Objective

Make release channels truthful and understandable from CI through the client.
AgentOS keeps `stable`, `beta`, `edge`, and `none`; beta is the release-candidate
channel. No additional RC channel or dynamic update server is introduced.

## Tech stack

- GitHub Actions signed build/promotion workflow
- Static signed pacman repositories and release manifests on GitHub Pages
- Go channel/repository validation in `agentos-ops`
- JSON metadata in `release/channels/`

## Commands

```bash
bash tests/release-static.sh
bash tests/release-promotion.sh
bash tests/pages-overlay.sh
bash tests/fetch-live-channel.sh
bash tests/set-channel.sh
bash tests/doctor-repository-invariant.sh
git diff --check
```

## Project structure

- `.github/workflows/release.yml` builds edge and promotes unchanged bytes.
- `release/` owns signed manifests, channel overlays, and client metadata.
- `docs/release-promotion.md` and `docs/releasing.md` describe operator truth.
- `core/cmd/agentos-ops/` validates channel/repository agreement.

## Code style

Channel values are a closed enum, not free-form strings:

```go
switch channel {
case "stable", "beta", "edge", "none":
default:
	return fmt.Errorf("invalid AgentOS channel: %s", channel)
}
```

Release metadata names source commit, source run, channel, version, generation
time, and cryptographic identity explicitly.

## Testing strategy

- Verify edge -> beta -> stable source restrictions and byte preservation.
- Verify publishing one channel preserves other live channel directories.
- Verify docs and tests agree on which channels are publicly reachable.
- Verify clients reject invalid channels and repository URL drift.
- Inspect a live promoted channel separately from workflow/source evidence.

## Boundaries

- Always: stable defaults for friend installs; manual beta promotion; immutable
  promotion lineage; signed static artifacts; explicit channel labels in UI.
- Ask first: publish edge, automate beta promotion, expose channel switching in
  friend-facing UI, or change stable cadence.
- Never: rebuild during promotion, silently move a friend off stable, add RC as
  an alias for beta, or infer deployment from CI success.

## Success criteria

- Documentation, workflow behavior, Pages layout, and client channel selection
  describe the same publication model.
- Beta is documented and displayed as the candidate/testing channel.
- Stable remains the only auto-updating friend default; beta/edge do not mutate
  on the weekly timer.
- Signed update metadata supplies the Update Center with current and available
  AgentOS versions without a dynamic service.
- Promotion and live-channel verification tests pass.

## Open questions

None for the first release. Beta promotions publish the supervised candidate at
`/beta`, stable promotions publish `/stable` and stable-root assets, and edge
remains artifact-only unless separately approved for publication.

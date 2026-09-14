# AgentOS release promotion

The immutable artifact path is:

```text
successful main push -> signed edge artifact -> explicit beta promotion
                                             -> explicit stable promotion
```

Promotion verifies signatures and checksums, then copies package, database,
and VPS bootstrap bytes unchanged. Only the channel manifest and its signature
change. Each manifest records the source channel, manifest checksum, and run ID.

## Operating the channels

1. A successful `main` push uploads `agentos-edge-repository` with the exact
   source commit. Edge is an Actions artifact; it is not deployed to Pages.
2. Dispatch `AgentOS Release` on `main` with `channel=beta` and the successful
   main push `source_run_id`. This publishes `/beta`, preserving `/stable`
   and the stable root installer. Enable `build_iso` to build a beta installer
   from the promoted package bytes and their source commit in the same run.
3. Complete the [community beta acceptance gates](community-beta.md).
4. Only after acceptance, dispatch `channel=stable` with the successful beta
   promotion run ID. This publishes `/stable` and refreshes the root installer.

Automatic stable promotion is disabled. No workflow selects the newest beta
implicitly. Every promotion requires an explicit source run on `main`.
The existing stable client update timer is separate and remains enabled;
beta clients do not run that scheduled update.

Each deployment restores existing published channel directories before
replacing the selected channel. The workflow summary records the source run,
commit, artifact, and idempotency key. Preserve the previous stable artifact
for recovery; Actions artifact retention is 30 days.

## Verification boundary

A signed artifact, successful workflow, or Pages download does not establish
VM or physical acceptance. ISO signatures/checksums, installed-disk boot,
input, real agent tasks, update, and boot-safe rollback are separate gates.
See [the release procedure](releasing.md) and
[system acceptance](friend-system-acceptance.md).

# AgentOS release procedure

The community beta targets x86_64 Arch workstations. The public source uses fresh history. Signed build, download, and device
acceptance gates must pass before a community installer is released.
Do not redirect users to a repository or download that has not been verified
anonymously. Public content must contain no private diagnostics or credentials.

## Package and repository candidate

Use a clean checkout of the reviewed commit. Run `tests/static.sh`,
`tests/release-static.sh`, `tests/package-version.sh`, `tests/repository-trust.sh`,
the integration and signature suites from `.github/workflows/ci.yml`, and
`go test ./...` in `core`. Build packages on x86_64 Arch, then run package-content
and package-install-migration checks against those archives.

Main push builds and verifies a signed edge artifact. Explicit promotion to
beta publishes `/beta`; stable files and the root installer are preserved.
Stable promotion requires an explicit accepted beta run. There is no weekly
server-side promotion. The stable client update timer is a separate policy.
See [channel operation](release-promotion.md).

## Versioned ISO

For the beta candidate, dispatch the release workflow on `main` with
`channel=beta`, `build_iso=true`, and the successful main push `source_run_id`.
The ISO job checks out that artifact's source commit and embeds the promoted
signed beta packages. The installer carries beta through bootstrap, repository
configuration, and first-use config. An edge-only build remains available with
`channel=edge`, `build_iso=true`, and no source run; edge is not published to
Pages and therefore is not the community installation path.

The build requires a clean tracked checkout and an explicit source revision.
It exports only committed files with `git archive`; local screenshots, caches,
untracked files, and Git history do not enter the ISO. The signed package
manifest must match the selected source commit and channel. The ISO is labeled
using the verified manifest version; the embedded installer records
that same version on the installed system. An explicit `AGENTOS_VERSION`
override must match the signed manifest. Arch dependencies
are downloaded into an embedded local repository; they are rolling inputs,
so a source commit alone does not imply a byte-reproducible ISO.

The immutable Actions artifact includes the versioned ISO, portable SHA-256
checksum, detached ASCII-armored signature, and a JSON manifest recording
commit, channel, version, filename, and checksum. Preserve all four together.
Verify the checksum and signature independently using the committed public key
and fingerprint before testing. Never put the private signing key in the ISO.

For an approved local x86_64 Arch build, set `AGENTOS_SOURCE_REV` to the exact
reviewed HEAD, `AGENTOS_CHANNEL=beta`, `AGENTOS_REPO` to the public HTTPS source
URL, and `AGENTOS_SIGNED_REPO_DIR` to the matching verified beta repository,
then run `bash build-agentos-iso.sh` as an unprivileged user. The build invokes
sudo; approve package and build operations on that target first.

A beta build dispatch also publishes the beta package channel. It does not
create a public GitHub Release or claim installer acceptance. Publish the
exact tested ISO bytes, checksum, signature, and manifest only after both VM
and spare-PC acceptance. Check each public download without authentication.

## Public source and presentation

Use `bash release/export-source.sh COMMIT NEW_DIRECTORY` to prepare a tree
without Git history. Review its file inventory and contents before initializing
fresh history. The export is a source snapshot, not a secret scanner. Retain
LICENSE and third-party notices. Exclude private plans, logs, captures, and
historical operator reports; never push the private Git object database.

Choose the new repository identity before changing trust/download/source URLs.
Configure Actions, Pages, protected signing secrets, the public trust anchor,
Codex review, issue templates, and contribution routes in the new repository.
Run CI, build/sign, verify downloads anonymously, and only then redirect users.
Do not copy credentials or change the signing trust anchor casually.

For a fresh repository with no stable channel, set its Actions variable
`AGENTOS_VERSION_BASE_URL` to the existing public repository base URL. CI then
compares package versions against that stable baseline without publishing an
unaccepted candidate as stable. After the new stable channel is accepted and
published, remove the variable to use the new repository's own baseline.

Use real accepted-candidate desktop screenshots and a working short demo on
the existing landing page. Prepare announcement text locally; community posts
and invitations need separate authorization. See [community beta](community-beta.md).

## Evidence and recovery

Record commit, workflow run, package versions, ISO checksum, target hardware,
commands and exit codes, first errors, and screenshots. Historical QA does not
accept this candidate. Require zero known data-loss/security blockers and no
broken core journey before publication. Preserve the previous stable artifact
and boot-safe snapshots; never erase a target or reboot without authorization.

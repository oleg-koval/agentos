# Friend-system acceptance

Use this runbook for the AgentOS candidate after source and package validation.
It separates reproducible build evidence from disposable-VM and physical-device
evidence. Passing one layer does not imply that a later layer passed.

## 1. Source and package candidate

Run in the candidate checkout on x86_64 Arch:

```bash
bash tests/static.sh
bash tests/release-static.sh
bash tests/package-version.sh
cd core && go test ./... && go build ./cmd/agentosd2 && go build ./cmd/agentos-ops
cd ..
# Run this build command as an unprivileged build user.
bash repository/build-repo.sh
bash tests/package-content.sh out/repo/x86_64
bash tests/package-install-migration.sh out/repo/x86_64
```

Record the source commit and exact runtime/shell package filenames. Package
inspection proves shipped files and metadata; it does not prove a graphical
session, boot, firmware device, or physical input path.

## 2. Disposable x86_64 VM journey

Use a new UEFI VM with a dedicated virtual disk and Btrfs root. Keep console
access until the journey finishes. Installation, package mutation, reboot, and
rollback require operator approval even on the disposable target.

1. Install only the candidate packages and confirm there is no source checkout.
2. Record `pacman -Q agentos-runtime agentos-shell` and run:

   ```bash
   agentos health
   agentos state
   agentos repository status
   agentos update --check
   agentos migrate status --json
   agentos hardware --json
   agentos recovery --json
   systemctl --failed --no-pager
   systemctl --user --failed --no-pager
   ```

3. Open AgentOS Home and its Chromium fallback. Verify the same Start here,
   Update Center, Hardware readiness, Recovery Center, Connectivity, and
   Support & privacy semantics in both clients. Check keyboard-only focus at
   100% and 150% scaling and at 1280x720 and 1920x1080.
4. Run **Check**, then **Update now** against the signed candidate repository.
   Confirm the visible authorization flow, durable result, recovery-point ID,
   migration result, and absence of an automatic reboot.
5. In a test-only migration directory, inject one successful migration followed
   by one failing migration. Confirm the failure is recorded, later work is not
   run, and retry succeeds after fixing only the failing fixture.
6. Create a boot-safe recovery point, stage it, cancel it, then stage it again.
   Confirm each state change before rebooting. Reboot once into the recovery
   point, then reboot normally and confirm the regular boot entry was not
   rewritten.
7. Create a local support report, review it for secrets, and verify no upload
   occurred. Do not enable telemetry for this test.

Firmware apply is not part of the VM journey. `fwupd` remains optional and its
enable, remote configuration, apply, and reboot decisions stay separate.

## 3. Physical acceptance

Run only after the VM journey passes and the operator approves the target,
firmware actions, reboot, and rollback separately. Verify direct or FreeRDP
display, keyboard, mouse, resize, suspend/resume, update reboot health, and a
one-shot rollback while retaining SSH or console recovery access. Preserve the
Chromium fallback.

## Evidence record

Record the candidate commit, package filenames and hashes, machine role,
firmware action taken or `not run`, update result, migration result, recovery
point and next-boot state, reboot/return result, GUI evidence method, support
report review, and every skipped check. A clean source test or CI run must never
be reported as VM or physical acceptance.

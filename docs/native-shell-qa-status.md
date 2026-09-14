# Native shell QA status

Native Workspace is the default graphical surface; Chromium Home remains the
recovery fallback. Historical cutover checks do not accept the community beta
candidate. Current candidate device acceptance is pending.

Use [community beta acceptance](community-beta.md) and
[system acceptance](friend-system-acceptance.md) to record exact source,
package and ISO identities, hardware, commands, and visual evidence.

Verify keyboard, pointer, focus, resizing, project/session switching, daemon
failure, provider unavailability, and native/Chromium lifecycle recovery on
the candidate. API health, source tests, CI, and signed packages cannot prove
physical input or display behavior.

## Known input limitation

macOS may consume Command/Meta shortcuts before FreeRDP forwards them.
Use `Ctrl+Alt+1..4` and `Ctrl+Alt+H` for the documented remote workspace and
Home shortcuts. Verify these on the actual client and candidate before
reporting acceptance. Preserve localhost API and browser/Python IPC behavior.

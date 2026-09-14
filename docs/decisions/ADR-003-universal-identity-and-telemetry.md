# ADR-003: Universal identity and privacy-preserving support data

## Status

Accepted for the universalization release; public repository and telemetry
service decisions remain deployment-specific.

## Decision

AgentOS uses generic installed identity by default:

- the product identity is `AgentOS`;
- new state, configuration, rollback, and source-discovery paths use
  `agentos` names;
- the Linux login, hostname, source repository, and dotfiles repository are
  selected by the installer or operator rather than embedded personal values;
- one-release compatibility aliases may read or clean prior paths, but new
  writes use canonical paths.

The source update path requires `AGENTOS_REPO`, an existing checkout remote, or
`/etc/agentos/repository-url`. This prevents a new installation from silently
cloning an unrelated or owner-specific repository.

The runtime's Go module uses the provider-neutral local path `agentos/core`
until a canonical public source host is selected. It is not presented as a
stable import path for downstream Go libraries.

Support reporting is local and redacted. `agentos support` excludes logs by
default; `--include-logs` is explicit, output is mode `0600`, and no upload is
performed by AgentOS.

Reliability telemetry is disabled by default. When explicitly enabled, the
local queue stores only an allow-listed event name, coarse success/failure
outcome, timestamp, schema, and a deterministic event ID for deduplication.
Prompts, commands, paths, usernames, project names, host information, tokens,
and document contents are excluded. A remote collector is never contacted
automatically: an operator must configure an HTTPS endpoint and run the manual
upload command. Endpoint ownership, retention, disclosure, and consent remain
deployment decisions.

## Consequences

Fresh installations are portable across owners, machines, and VPS providers.
Existing installations continue to find legacy state through explicit aliases.
The release can support centrally aggregated reliability statistics only when a
privacy-reviewed collector is selected, configured, and deployed.

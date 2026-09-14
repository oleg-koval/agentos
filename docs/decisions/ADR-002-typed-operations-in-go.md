# ADR-002: Typed workstation operations in Go

## Decision

Stateful AgentOS operations use one Go binary, `agentos-ops`, with explicit
entrypoints for the CLI, capability registry, declarative config application,
signed repository management, update policy, remote validation, health checks,
and convergence transactions. The existing `agentos-*` shell files remain
small compatibility shims for source checkouts and callers that already use
those names.

## Why Go

The runtime and daemon are already Go, the stable package build already
requires Go, and Go produces straightforward static binaries for Arch and
systemd. Reusing that toolchain avoids a second compiler, dependency graph,
lint configuration, and package ownership model. The operations are mostly
process execution, HTTP, JSON, filesystem state, and small policy decisions;
Go's standard library covers those needs directly.

Rust remains a good choice for memory-sensitive libraries, complex parsers, or
security-critical low-level components. It is not justified for this phase:
introducing it would increase release and recovery surface without replacing a
current Rust component or solving a demonstrated defect.

## Compatibility and boundary

The shims preserve command names and arguments, including the CLI's daemon
actions and privileged delegation. Destructive disk provisioning,
USB creation, boot-entry manipulation, and other narrow system-tool
orchestration remain shell glue; Go owns validation, ordering, structured state,
and failure policy around those operations.

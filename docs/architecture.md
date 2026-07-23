# Architecture

## Source and projection

Git-tracked YAML/Markdown is the portable authority. Core validates that input
and rebuilds `.worklog/projection.sqlite3`; deleting the database must not lose
user data. Flutter and CLI call the same Dart Core.

```text
Flutter / CLI
     │
     ▼
Dart Core ───── RunnerAdapter
     │               │
     ├─ Git YAML      └─ explicit skill invocations + audit
     └─ local SQLite projection
```

Stable IDs use typed prefixes such as `DOM-`, `MLS-`, `TSK-`, `CTL-`, `OP-`,
and `RUN-`. Domain, Milestone, Objective, Knowledge, and Reference are portable
entities; Task references them by ID rather than embedding all context.

## Execution invariants

1. Draft revision must equal the approved Meta source revision.
2. One `operation_id` reserves exactly one `run_id`.
3. Control requests are append-only. A disposition has its own immutable file
   and a unique `request_id`.
4. Every execution invokes `under-claw-work-plan`. Its validated nested trace
   invokes `under-claw-meta-prompt`, then `under-claw-jarvis-plan-loop`; every
   loop round invokes `under-claw-jarvis-plan`.
5. RunnerAdapter absorbs provider differences. Task data does not require a
   model ID.

## Hermes boundary

Current Hermes upstream exposes skills at
`${HERMES_HOME:-~/.hermes}/skills/`, native `hermes skills` lifecycle commands,
and deterministic loading with
`hermes chat -s under-claw-work-plan -q "<request>"`. Under Claw Work does not
modify Hermes Core and does not use a project plugin for the MVP. The four
skills remain independent; the orchestration skill records actual nested
invocation evidence in the Git canonical workspace.

This is a verified upstream/process contract. Live remote E2E remains
separately gated and is never inferred from a fixture.

## Current boundary

This first implementation is an executable vertical slice, not the complete
distribution. The external cross-device authentication provider is unselected
and release artifacts are unsigned. The UI therefore exposes no password setup
that could imply an unsafe protocol.

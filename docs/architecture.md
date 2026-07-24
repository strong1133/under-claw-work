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
execution skills remain independent; the orchestration skill records actual nested
invocation evidence in the Git canonical workspace.

The provider-neutral bundle contains the local `under-claw-work` capability
guide, the local `under-claw-work-plan` governed entry point, and the pinned
upstream `under-claw-meta-prompt`, `under-claw-jarvis-plan-loop`, and
`under-claw-jarvis-plan` skills.

Skill installation is supported for Hermes without changing Hermes Core.
Automated Hermes Task execution is a separate adapter boundary: live remote E2E
and reviewer attestation remain gated and are never inferred from a fixture.

## Automatic Meta Prompt control plane

Draft Prompt and generated Meta Prompt remain separate revisions. The existing
`prompt_approval` lifecycle (`missing`, `stale`, `pending`, `approved`) is the
single prompt-state authority. A Git-ref compare-and-set lease prevents the
MacBook and Astro-Hermes from generating the same revision concurrently.
Generation explicitly executes the checksum-pinned `under-claw-meta-prompt`
adapter, and the Meta, Run, SkillInvocation, and Event records are published in
one validated Git transaction. Approval and Task execution remain manual.

Post-commit notifications use local-only FCM/Hermes webhook credentials. Failed
delivery enters a retryable local outbox and never rolls back canonical data.
See [auto-meta-notifications-update.md](auto-meta-notifications-update.md).

## Runtime updates

Manifest-verified extracted releases are candidate-built, health-checked, and
atomically swapped. The previous runtime is retained for an explicit rollback.
The release manifest guarantees archive integrity but not publisher authenticity.

## Current boundary

This first implementation is an executable vertical slice, not the complete
distribution. The external cross-device authentication provider is unselected
and release artifacts are unsigned. The UI therefore exposes no password setup
that could imply an unsafe protocol.

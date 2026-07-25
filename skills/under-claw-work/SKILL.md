---
name: under-claw-work
description: Explain and route Under Claw Work capabilities.
---

# Under Claw Work

Use this skill when the user explicitly asks what Under Claw Work is, what it
can do, which skills it includes, or which command should handle a workflow.
It explains and routes; it does not silently execute another skill.

## Identity

Under Claw Work does not replace Hermes, Claude Code, Codex, or their models.
It is a provider-neutral tool and skill collection used by those hosts.

It provides:

- quick Draft and governed Task records;
- current-revision Meta Prompt generation and approval;
- immutable control, Run, skill-invocation, review, and Event audit;
- portable Domain, Milestone, Objective, Knowledge, and Reference records;
- Domain/Milestone-scoped Project, Repository, Persona, Agent Group, Channel,
  MCP, and Skill Policy records with host-local path/profile bindings;
- Git YAML/Markdown canonical storage and rebuildable SQLite projection;
- optional Notion mirroring;
- runtime adapters that remain fail-closed until verified.
- cross-host automatic Meta generation with Git-ref claim leases;
- post-commit FCM and Hermes/Discord notifications with a retry outbox;
- manifest-verified runtime update and rollback.

## Included skills

| User intent | Route |
|---|---|
| Explain, inspect, or choose a workflow | Stay in `under-claw-work` |
| Execute a governed Worklog Task | Explicitly invoke `under-claw-work-plan` |
| Generate or improve only a Meta Prompt | Explicitly invoke `under-claw-meta-prompt` |
| Run iterative implementation and review | Explicitly invoke `under-claw-jarvis-plan-loop` |
| Run one staged plan workflow | Explicitly invoke `under-claw-jarvis-plan` |

The Meta, loop, and plan skills are supplied by the checksum-pinned
`strong1133/under-claw-jarvis-plan` upstream bundle.

## Rules

1. Preserve the original Draft independently from generated Meta.
2. Do not execute without an approved Meta for the current Draft revision.
3. Do not treat a skill name in prose as an invocation.
4. Do not claim automated host support without verified runtime evidence.
5. Keep provider/model details out of portable Task content.
6. Store secrets only through approved local secure stores, never Git.

## Useful CLI routes

```text
worklog task-list <workspace>
worklog task-create <workspace> <domain> <milestone> <title> <environment>
worklog task-prompt <workspace> <task> <draft|meta|approve> [content-file]
worklog meta-generate <workspace> <task-id> <adapter-id>
worklog auto-meta-next <workspace> <environment-id> <adapter-id>
worklog notification-register <workspace> <local-config-json>
worklog notification-list <workspace>
worklog entity-list <workspace> [kind]
worklog entity-create <workspace> <kind> <title> [domain-id] [milestone-id]
worklog scope-config-create <workspace> <kind> <descriptor-json-file>
worklog context-resolve <workspace> <domain-id> [milestone-id] [channel-id]
worklog host-binding-set <workspace> <descriptor-json-file>
worklog mcp-serve <workspace> <domain-id> [milestone-id]
worklog memory-recall <workspace> <domain|milestone|task> <scope-id>
worklog context-build <workspace> <task>
worklog task-control <workspace> <task> <start|pause|resume|cancel|complete>
worklog runtime-list <workspace>
worklog git-sync <workspace> [commit-message]
worklog update-check|update-apply <extracted-release-directory>
worklog update-rollback
```

If the user asks to perform one of these operations, inspect the workspace and
use the CLI directly when authorized. If they ask for a nested skill workflow,
name the required explicit skill and wait for or perform that explicit
invocation according to the host's skill-loading rules.

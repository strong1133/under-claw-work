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
It is a provider-neutral tool and skill collection used by those hosts — a set
of skills plus the working discipline around them, shared by the AI setup on a
workstation and by a Hermes agent on a remote host.

The memory repository is the user's, not the product's. Installation asks for
the path to it and touches nothing else; from that point on, tailoring the
Domains, Milestones, Personas, Skill Policies, and host bindings inside it is
the user's own area. Do not restructure a user's workspace, invent Domains, or
migrate their records unless they ask for that specific change.

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
7. Keep local absolute paths out of canonical entities. Legacy imports that
   carry them record the value in the migration report instead, and binding a
   path to a Repository entity stays an explicit user decision.
8. Treat the user's memory repository as theirs: change only what was asked.

## Meta Prompt authoring loop (host Agent, no runtime adapter)

This is the practical path on a workstation host such as Claude Code or Codex,
where no verified `generate_meta` runtime adapter is registered. The host Agent
supplies the reasoning; Under Claw Work supplies the queue and the record.

1. The user marks a Draft as awaiting Meta:
   `worklog task-prompt <workspace> <task-id> request-meta`
2. Poll the queue. Each row is `task-id`, state, Draft revision, canonical file
   path, and title:
   `worklog task-pending-meta <workspace>`
3. Read the Draft from the canonical path in that row.
4. Invoke `under-claw-meta-prompt` explicitly and write its output to a file.
   Naming the skill in prose is not an invocation.
5. Record the result against the same Draft revision:
   먼저 `worklog task-meta-evidence ... > evidence.json`으로 Core가 Draft/Meta
   hash와 portable result ref를 계산하게 한 뒤
   `worklog task-meta-record <workspace> <task-id> <meta-file> evidence.json`
6. The user reviews and approves:
   `worklog task-prompt <workspace> <task-id> approve`

Editing the Draft after step 5 returns the Task to `writing` and makes the
approval stale, so step 4 must re-run. `auto-meta-next` covers the same loop on
a remote Hermes host that does have a verified adapter; do not claim automatic
generation on a host without one.

## Useful CLI routes

```text
worklog task-list <workspace>
worklog task-pending-meta <workspace>
worklog task-create <workspace> <title> [--domain <domain>] \
  [--milestone <milestone>] [--environment <environment>]
worklog task-prompt <workspace> <task> <draft|approve|request-meta> [file]
worklog task-meta-evidence <workspace> <task> <meta-file> <bundle-version> <bundle-sha256> <host-invocation-id> <host-id> <runner-id> <started-at> <finished-at> [environment]
worklog task-meta-record <workspace> <task> <meta-file> <evidence-json>
worklog meta-generate <workspace> <task-id> <adapter-id>
worklog auto-meta-next <workspace> <environment-id> <adapter-id>
worklog notification-register <workspace> <local-config-json>
worklog notification-list <workspace>
worklog entity-list <workspace> [kind]
worklog entity-create <workspace> <kind> <title> [domain-id] [milestone-id]
worklog reference-attach <workspace> <title> <file> [domain] [milestone] [task]
worklog migrate-dry-run <workspace> <legacy-path>
worklog migrate-import <workspace> <legacy-path> <domain> <milestone> <env> \
  --approve [--map <map-json-file>]
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

# Agent and model context

Under Claw Work is a provider-neutral work control and durable memory layer. It
does not replace the host Agent or its model.

```text
Hermes / Claude Code / Codex / compatible host
                    │
          installed Under Claw skills
                    │
       Under Claw Work CLI · Flutter · Core
                    │
       Git YAML/Markdown canonical workspace
                    │
      disposable SQLite · optional Notion mirror
```

## What hosts can do

1. Capture a user's original request as a Task Draft.
2. Link Domain, Milestone, Objective, Knowledge, Reference, Environment, and
   related Tasks without embedding provider details.
3. Generate a Meta Prompt through `under-claw-meta-prompt`, retain its source
   Draft revision, and wait for approval.
4. Execute an approved Task through `under-claw-work-plan`.
5. Run `under-claw-jarvis-plan-loop`, with
   `under-claw-jarvis-plan` explicitly invoked in every round.
6. Record immutable controls, Runs, skill invocations, review evidence, Events,
   learned Knowledge, and policy-approved follow-up Task candidates.
7. Recall portable Knowledge across supported hosts and environments.

## Included skill bundle

| Skill | Purpose | Activation |
|---|---|---|
| `under-claw-work` | Explain capabilities and route commands | Explicit |
| `under-claw-work-plan` | Governed Task workflow and audit | Explicit |
| `under-claw-meta-prompt` | Draft-to-Meta transformation | Explicit |
| `under-claw-jarvis-plan-loop` | Iterative implementation and review | Explicit |
| `under-claw-jarvis-plan` | Understand, plan, implement, verify | Explicit |

The last three skills are copied from the checksum-pinned
`strong1133/under-claw-jarvis-plan` upstream revision recorded in
`skills/bundle.lock.yaml`.

## Context files

The repository root uses:

- `AGENTS.md` for Codex, Hermes, and compatible project-context readers.
- `CLAUDE.md` for Claude Code; it imports the shared instructions.

Opt-in templates under `personas/` cover other host conventions and Hermes'
global `SOUL.md`. The installer never overwrites an existing global persona.
Project facts belong in `AGENTS.md`; stable voice belongs in `SOUL.md`.

## Honest capability boundary

Installing a skill into a host means that the host can load and use the skill.
It does not prove that the automated Task runner adapter has passed acceptance
tests. Automated execution remains fail-closed until a reviewed runtime
descriptor is registered.

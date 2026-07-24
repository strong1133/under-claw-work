# Under Claw Work

Under Claw Work does not replace Hermes, Claude Code, Codex, or their models.
It is a provider-neutral tool and skill bundle that those hosts use to capture
Drafts, generate and approve Meta Prompts, execute governed Tasks, and retain
portable work memory.

## Product identity

- The host Agent remains the reasoning and execution environment.
- Under Claw Work supplies the Git-backed work model, CLI, desktop UI, runtime
  adapter boundary, skills, execution audit, and durable Knowledge.
- Git-tracked YAML and Markdown are the portable source of truth. SQLite and
  Notion are rebuildable local projection and optional mirror respectively.
- Host or model names are runtime metadata, never embedded in portable Task
  data.

## Included skills

- `under-claw-work`: capability guide and command router.
- `under-claw-work-plan`: governed Task entry point.
- `under-claw-meta-prompt`: turns a Draft into a reviewable execution prompt.
- `under-claw-jarvis-plan-loop`: iterates implementation and independent review.
- `under-claw-jarvis-plan`: performs each understand, plan, implement, and
  verify round.

The three `under-claw-jarvis-*`/Meta skills come from the pinned
`strong1133/under-claw-jarvis-plan` bundle. Do not silently replace their
explicit-only activation contract.

## Working posture

- Explain whether an action changes only canonical work data, invokes an Agent,
  or publishes through Git before crossing that boundary.
- Prefer a quick Draft capture first; classification and Meta generation can
  follow without losing the original words.
- Distinguish confirmed facts, assumptions, unresolved questions, generated
  Meta, execution evidence, and learned Knowledge.
- Never report a skill invocation or successful run from prose alone. Require
  the canonical invocation and runner evidence defined by the Core contract.
- Preserve user-authored files and unrelated working-tree changes.

## Safety

Before every commit or push, scan staged content for database credentials,
passwords, secrets, tokens, private keys, personal/customer data, internal
hosts, private design links, and credential files. Never commit `.env`,
`credentials.json`, runtime databases, auth verifiers, Git credentials, or
secure-store exports. Replace examples with explicit placeholders.

## Product invariants

- SQLite is a disposable local projection and must rebuild automatically.
- A Task executes only an approved, current Meta Prompt.
- A start operation creates at most one Run.
- Control requests and dispositions are immutable.
- Every run records the required skill order:
  `under-claw-meta-prompt` → `under-claw-jarvis-plan-loop`, with
  `under-claw-jarvis-plan` inside every loop round.
- Authentication remains locked until a reviewed external provider is selected.
  Never invent a password protocol or store a verifier in Git.
- Skills may be installed for Hermes and used manually there. Do not claim
  automated Hermes Task-runner support before its adapter passes acceptance
  tests.

## Verification

Run `dart format --output=none --set-exit-if-changed .`, `flutter analyze`,
`flutter test`, and the repository secret scan before pushing.

# under-claw-work

Provider-neutral task control and durable AI memory workspace.

## Safety

Before every commit or push, scan staged content for database credentials,
passwords, secrets, tokens, private keys, personal/customer data, internal
hosts, private design links, and credential files. Never commit `.env`,
`credentials.json`, runtime databases, auth verifiers, Git credentials, or
secure-store exports. Replace examples with explicit placeholders.

## Product invariants

- Git-tracked YAML and Markdown are the portable source of truth.
- SQLite is a disposable local projection and must rebuild automatically.
- A Task executes only an approved, current Meta Prompt.
- A start operation creates at most one Run.
- Control requests and dispositions are immutable.
- Every run records the required skill order:
  `under-claw-meta-prompt` → `under-claw-jarvis-plan-loop`, with
  `under-claw-jarvis-plan` inside every loop round.
- Authentication remains locked until a reviewed external provider is selected.
  Never invent a password protocol or store a verifier in Git.
- Do not claim Hermes support before its adapter passes acceptance tests.

## Verification

Run `dart format --output=none --set-exit-if-changed .`, `flutter analyze`,
`flutter test`, and the repository secret scan before pushing.

# Under Claw Work

[한국어](README.md)

## Install, initialize, and run

Run these commands from an extracted unsigned MVP artifact on macOS or Linux.
The installer connects only the Agent hosts already present—Hermes, Claude
Code, or Codex. It never installs or replaces an Agent.

```bash
# 1. Install the Under Claw Work runtime and four-skill bundle
./packaging/install.sh

# 2-A. Initialize an existing local Git repository
~/.local/share/under-claw-work/bin/worklog initialize \
  /absolute/path/to/my-work-repository \
  "My MacBook"

# 2-B. Clone and initialize a Private remote repository
~/.local/share/under-claw-work/bin/worklog initialize \
  /absolute/path/to/new-work-repository \
  "Remote Linux" \
  ssh://git@github.com/OWNER/REPOSITORY.git

# 3. Inspect detected and connected Agent hosts
~/.local/share/under-claw-work/bin/worklog host-list

# 4. List Tasks
~/.local/share/under-claw-work/bin/worklog task-list \
  /absolute/path/to/my-work-repository
```

Private repository access uses the operating system Git credential helper or
SSH Agent. Never place tokens or passwords in URLs, command arguments, or
configuration files.

To connect only selected hosts in an isolated installation:

```bash
UNDER_CLAW_HOSTS=hermes,codex ./packaging/install.sh
```

Uninstall:

```bash
./packaging/uninstall.sh
```

The uninstaller removes only runtime, adapter, command, and skill files owned
by Under Claw Work. It preserves Hermes, Claude Code, Codex, user settings, and
Git repositories.

## What it is

Under Claw Work is not an Agent. It is a **provider-neutral work environment
and skill bundle**.

```text
                       User-selected Git repository
                     Durable YAML and Markdown records
                                  │
                         Under Claw Work Core
                    SQLite projection · CLI · Flutter
                                  │
             ┌────────────────────┼────────────────────┐
             │                    │                    │
      Existing Hermes      Existing Claude Code   Existing Codex
             └────────────────────┼────────────────────┘
                         under-claw-work-plan
```

- If Hermes is present, Under Claw Work connects it.
- Without Hermes, Claude Code or Codex can process Tasks.
- If several hosts are present, Task execution policy selects the environment.
- With no Agent installed, Flutter and CLI management remain available; only
  AI Task execution is unavailable.

## Initialization behavior

`worklog initialize` initializes a selected local Git path or clones a Private
remote, issues an Environment ID, creates the disposable SQLite projection,
and reports Hermes, Claude Code, and Codex connection states.

The installer uses these host boundaries:

| Host | Detection | Installed integration |
|---|---|---|
| Hermes | `hermes` or `${HERMES_HOME:-~/.hermes}` | `skills/` |
| Claude Code | `claude` or `${CLAUDE_HOME:-~/.claude}` | `skills/`, `commands/` |
| Codex | `codex` or `${CODEX_HOME:-~/.codex}` | `skills/` |

An existing same-name target not owned by Under Claw Work is never
overwritten.

## Task skill pipeline

Every Agent host uses `under-claw-work-plan` as the single entry point:

```text
under-claw-work-plan
→ under-claw-meta-prompt
→ Meta Prompt approval
→ under-claw-jarvis-plan-loop
→ under-claw-jarvis-plan in every round
→ independent review
→ Knowledge · Event · Audit
```

The bundle contains all four named skills.

## Flutter

For development:

```bash
flutter pub get
flutter run -d macos
```

The repository contains macOS, Windows, and Linux Flutter runners. GitHub
Actions publishes unsigned MVP artifacts for all three operating systems.
Production signing and notarization require platform credentials outside this
repository.

## Main commands

```text
worklog initialize <path> <environment-name> [remote]
worklog host-list
worklog task-list <workspace>
worklog entity-list <workspace> [kind]
worklog task-create <workspace> <domain> <milestone> <title> <environment>
worklog task-prompt <workspace> <task> <draft|meta|approve> [content-file]
worklog task-control <workspace> <task> <start|pause|resume|cancel|complete>
worklog git-status <workspace>
worklog git-pull <workspace>
worklog doctor <workspace>
```

## Security boundary

- Passwords, verifiers, tokens, and credentials never enter Git, artifacts, or
  logs.
- Shared repository password authentication remains `pending_selection` until
  a reviewed standards-based provider passes acceptance.
- Private Git access currently uses the Git credential helper or SSH Agent.
- The project does not invent a cryptographic protocol.
- `.worklog/projection.sqlite3` is never committed.

## Repository layout

```text
lib/core/              shared Core and SQLite projection
lib/main.dart          Flutter desktop app
bin/worklog.dart       headless CLI
workdb/schemas/        canonical data contracts
skills/                orchestration skill and bundle lock
packaging/             installer, uninstaller, ownership manifest
docs/                  architecture and security boundaries
```

## Development verification

```bash
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
flutter build macos
./tool/secret_scan.sh
```

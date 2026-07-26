# Under Claw Work

[한국어](README.md)

## Install, initialize, and run

Run these commands from an extracted unsigned MVP artifact on macOS or Linux.
The installer connects existing Hermes, Claude Code, and Codex hosts to the
skill bundle. It never installs or replaces an Agent, model, or global persona.
Skill use and automated Task-runner support are separate boundaries. Hermes can
use the skills while its automated runner remains fail-closed until adapter
acceptance passes.

```bash
# 1. Install the Under Claw Work runtime and five-skill bundle
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
./packaging/uninstall.sh --mode app
./packaging/uninstall.sh --mode runtime
./packaging/uninstall.sh --mode full --workspace /absolute/clone \
  --confirm-full /absolute/clone
```

`app` removes launchers/commands, and `runtime` also removes owned runtime and
skills. `full` requires an exact absolute-path confirmation and deletes only a
workspace cloned by Under Claw Work. Adopted repositories and Agent
installations are preserved.

## What it is

Under Claw Work does not replace an Agent. It is a **provider-neutral work
environment, tool, and skill bundle** used by Hermes, Claude Code, Codex, and
compatible hosts.

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

- Hermes receives the verified skill bundle like other hosts. Its automated
  Task runner still fails closed until acceptance passes.
- Any available host can use the skills and management tools.
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

Use `under-claw-work` for capability discovery and routing, and
`under-claw-work-plan` as the governed Task execution entry point:

```text
under-claw-work-plan
→ under-claw-meta-prompt
→ Meta Prompt approval
→ under-claw-jarvis-plan-loop
→ under-claw-jarvis-plan in every round
→ independent review
→ Knowledge · Event · Audit
```

The bundle contains five skills:

- `under-claw-work`
- `under-claw-work-plan`
- `under-claw-meta-prompt`
- `under-claw-jarvis-plan-loop`
- `under-claw-jarvis-plan`

The last three are packaged from the pinned and checksum-verified
[`strong1133/under-claw-jarvis-plan`](https://github.com/strong1133/under-claw-jarvis-plan)
revision. Native host context and opt-in persona templates live in
[`personas/`](personas/). The installer never overwrites an existing
`AGENTS.md`, `CLAUDE.md`, or `SOUL.md`.

## Management and review surfaces

Four views of the same canonical data. **Only the CLI and the desktop app
write.** Status transitions and Meta approval must pass evidence gates, so the
read-only surfaces never expose them.

| Surface | Use | Writes |
|---|---|---|
| Desktop app (Flutter) | author Tasks, request and approve Meta, control runs | yes |
| `worklog` CLI | everything above plus automation | yes |
| Derived Obsidian vault | read prompts, follow the graph and backlinks | no |
| Local browser view | browse, search, read prompts | no |

### Derived Obsidian vault

The canonical Draft and Meta live inside `task.yaml`, which Obsidian cannot open
as a note. Rather than splitting the canonical record, project it:

```bash
worklog obsidian-export <workspace>          # defaults to .worklog/obsidian/
worklog obsidian-export <workspace> <vault>
```

Note filenames are canonical IDs, so `[[TSK-...]]` links, graph view, and
backlinks follow canonical relations. The projection is one-way: edits in the
vault never reach canonical data and are overwritten on the next export. The
default location sits under `.worklog/`, so it is never committed. Exporting
into a non-empty directory this tool does not own is refused.

### Local browser view

```bash
worklog serve <workspace> [port]
```

Each launch mints a one-time token and prints it with the URL.

- Binds the loopback interface only; no option exposes another interface.
- Every request must present the token, which never reaches Git, canonical
  data, or a log.
- A non-loopback `Host` header is rejected, which blocks DNS rebinding.
- No CORS header is ever sent, so another origin cannot read a response.
- There is no write endpoint; every method other than `GET` is refused.

This token authenticates a local transport session. It is not the repository
password, which stays locked until a reviewed provider is selected.

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
worklog entity-create <workspace> <kind> <title> [domain] [milestone]
worklog entity-update <workspace> <kind> <id> <title>
worklog entity-archive <workspace> <kind> <id>
worklog entity-link <workspace> <kind> <id> <field> <target-kind> <target-id>
worklog graph-validate <workspace>
worklog knowledge-search <workspace> <query>
worklog context-build <workspace> <task>
worklog task-create <workspace> <title> [--domain <domain>] \
  [--milestone <milestone>] [--environment <environment>]
worklog task-policy <workspace> <task> <derive> <followup> <depth>
worklog task-candidate-list <workspace>
worklog task-candidate-dispose <workspace> <candidate> <accept|reject>
worklog task-prompt <workspace> <task> <draft|request-meta|approve> [content-file]
worklog task-meta-evidence <workspace> <task> <meta-file> <bundle-version> <bundle-sha256> <host-invocation-id> <host-id> <runner-id> <started-at> <finished-at> [environment]
worklog task-meta-record <workspace> <task> <meta-file> <evidence-json>
worklog task-control <workspace> <task> <start|pause|resume|cancel|complete>
worklog migrate-dry-run <workspace> <legacy-path>
worklog migrate-import <workspace> <legacy-path> <domain> <milestone> <environment> --approve
worklog migrate-rollback <workspace> <import-id>
worklog git-status <workspace>
worklog git-pull <workspace>
worklog obsidian-export <workspace> [vault-directory]
worklog serve <workspace> [port]
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
- `worklog serve` binds loopback only, requires the launch token, and has no
  write path.

## Memory repository layout

Initialization standardizes the memory repository the user chose. Git does not
track empty directories, so each canonical directory is seeded with a
placeholder and `workdb/workspace.yaml` records the layout version and the
directory list. A clone on another machine reproduces the same tree.

```text
<memory repository root>/
├─ workdb/          canonical, tracked by Git
│  ├─ workspace.yaml            layout manifest
│  ├─ tasks/ domains/ milestones/ objectives/ projects/ ...
│  ├─ knowledge/ references/ matches/
│  ├─ events/ runs/ claims/ invocations/ control-requests/ ...
│  └─ config/                   environments.yaml, agents.yaml, ...
└─ .worklog/        host-local, never tracked
   ├─ projection.sqlite3        rebuildable SQLite projection
   └─ obsidian/                 derived Obsidian vault
```

```bash
worklog doctor <workspace>   # workspace=ok | unversioned | version_mismatch
                             # | incomplete | not_portable
worklog init <workspace>     # repairs what the diagnosis reported
```

`doctor` diagnoses without repairing, so the owner sees the state before
deciding. The full specification is in
[`docs/최종계획/12-memory-repository-layout.md`](docs/최종계획/12-memory-repository-layout.md).
The tool guarantees the layout; the contents belong to the repository owner.

## Product repository layout

```text
lib/core/              shared Core and SQLite projection
lib/main.dart          Flutter desktop app
bin/worklog.dart       headless CLI
workdb/schemas/        canonical data contracts
skills/                Under Claw Work guide/runner skills and pinned bundle lock
personas/              native host context and opt-in persona templates
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

# Under Claw Work

Under Claw Work is a provider-neutral desktop workspace for domains,
milestones, tasks, prompts, execution control, and durable AI context.

This repository contains the Flutter source and the portable data contracts.
Each user selects a separate Git repository during setup; YAML and Markdown in
that repository are the source of truth, while SQLite is an automatically
rebuildable local projection.

It is a work environment and skill bundle, **not an Agent**. On macOS the
Flutter app and Core run standalone. On remote Linux an existing Hermes Agent
loads the installed skills and invokes the same headless Core.

## MVP implementation

- Flutter desktop shell for macOS, Windows, and Linux
- `worklog` Dart CLI for initialization, task listing, and diagnostics
- deterministic YAML Task loader and disposable SQLite projection
- canonical Domain/Milestone/Objective/Knowledge/Reference/Event/Claim/Run/
  Invocation/Control CRUD with relationship validation
- full canonical entity, relation, run, invocation, and control projection rebuild
- shared CLI/Flutter setup flow for a user-selected local Git path or Private
  remote (credentials remain in the platform Git credential helper)
- Draft/Meta revision and approval execution gate
- idempotent operation reservation and unique Run creation
- immutable start/pause/resume/cancel/complete ControlRequest and disposition
  storage, plus expiring claim heartbeat/takeover
- Git status, fast-forward pull, optimistic-head commit/push and explicit
  offline/divergence results
- provider-neutral RunnerAdapter and audited `under-claw-work-plan` pipeline
- executable process adapter with canonical invocation/event recovery
- revision-pinned skill source, entrypoint checksum verification and
  ownership/drift-aware uninstaller
- Flutter Task creation, Draft/Meta editing, approval and all control requests
- deliberately locked authentication boundary while provider selection is pending

Generic Domain/Milestone/Objective/Knowledge/Reference CRUD is available in
Core and the CLI projection browser; dedicated GUI editors and conflict
resolution UI remain follow-up work. Cross-device shared-password acceptance is
blocked pending an external provider. Artifacts are unsigned MVP test builds.

Hermes' current upstream skill boundary is contract-tested at
`${HERMES_HOME:-~/.hermes}/skills` and deterministic invocation is
`hermes chat -s under-claw-work-plan -q "<request>"`. A live remote Hermes E2E
has not yet been executed, so the repository does not claim production Hermes
support.

## Run

```sh
flutter pub get
flutter run -d macos
dart run bin/worklog.dart setup /path/to/user-workspace "My desktop"
dart run bin/worklog.dart init /path/to/user-workspace
dart run bin/worklog.dart task-list /path/to/user-workspace
dart build cli -o build/cli
UNDER_CLAW_SKILL_SOURCE=/path/to/under-claw-jarvis-plan ./packaging/install.sh
```

The CLI creates `.worklog/projection.sqlite3` itself. Users do not install or
configure SQLite.

## Repository layout

```text
lib/core/              shared Core and SQLite projection
lib/main.dart          Flutter desktop application
bin/worklog.dart       headless CLI entrypoint
workdb/schemas/        portable contract documentation
docs/                  implementation and security boundaries
packaging/             installer ownership manifest templates
skills/                four-skill bundle entrypoint and execution contract
```

## Authentication status

Repository authentication is intentionally locked with
`provider_selection_status: pending_selection`. A production provider must use
a reviewed PAKE or standard external authentication protocol and pass the
security acceptance tests. This codebase does not invent cryptography, return a
verifier to clients, or place password material in Git.

## Verify

```sh
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
flutter build macos
./tool/secret_scan.sh
```

GitHub Actions publishes clearly labelled unsigned MVP test artifacts for all
three desktop operating systems. Release signing and notarization require
platform credentials configured outside this repo.

# Under Claw Work

Under Claw Work is a provider-neutral desktop workspace for domains,
milestones, tasks, prompts, execution control, and durable AI context.

This repository contains the Flutter source and the portable data contracts.
Each user selects a separate Git repository during setup; YAML and Markdown in
that repository are the source of truth, while SQLite is an automatically
rebuildable local projection.

## Implemented vertical slice

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
- immutable ControlRequest/ControlDisposition storage
- provider-neutral RunnerAdapter and audited `under-claw-work-plan` pipeline
- deliberately locked authentication boundary while provider selection is pending

The current UI includes repository setup and reads and controls the vertical
slice. Full entity editors, pull/push/offline merge UX, reviewed cross-device
password authentication, signed installers, and validated host adapters remain
roadmap work. Hermes is not marked supported.

## Run

```sh
flutter pub get
flutter run -d macos
dart run bin/worklog.dart setup /path/to/user-workspace "My desktop"
dart run bin/worklog.dart init /path/to/user-workspace
dart run bin/worklog.dart task-list /path/to/user-workspace
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

Unsigned local development builds are not release artifacts. Release signing
and notarization require platform credentials configured outside this repo.

# Initial vertical slice design (2026-07-23)

## 1. Requirements and success criteria

Implement portable Task YAML, automatic SQLite projection, shared Core/CLI,
Flutter desktop viewing and start control, skill audit, and safe distribution
foundations in one private repository.

- YAML survives SQLite deletion and rebuild. [verify: Core test]
- stale/unapproved Meta cannot start. [verify: Core test]
- repeated operation creates one Run. [verify: Core test]
- disposition cannot be replaced. [verify: Core test]
- required skill order is audited. [verify: fake-runner test]
- Flutter source analyzes, tests, and builds on macOS. [verify: commands]
- no credential fixture is committed. [verify: secret scan]

## 2. Adopted approach and rationale

Use one Dart package for Core, CLI, and Flutter to keep contracts identical.
Keep Git files authoritative and SQLite disposable. Implement a narrow native
desktop control surface before broad CRUD. Authentication is a locked provider
contract until the security spike selects an external standard implementation.

Rejected: a server-first web application (explicitly unwanted), SQLite as the
sync authority (poor Git collaboration), and custom password cryptography
(unsafe and contrary to the approved design).

## 3. Scope and files

Core lives in `lib/core`, CLI in `bin`, Flutter in `lib/main.dart`, portable
contracts in `workdb/schemas`, and release foundations under `.github` and
`packaging`. No source planning repository files are changed.

## 4. Contract impact

`WorkTask`, `ControlRequest`, `RunnerAdapter`, and SQLite tables are the first
public contracts. Git workspace paths are passed at runtime; the product source
repository is never assumed to be the user's data repository.

## 5. Risks and unresolved assumptions

Auth provider remains pending selection. Windows/Linux builds require their own
CI runners. macOS output is unsigned locally. Real agent invocation adapters and
Hermes acceptance are follow-up work.

## 6. Verification

Format, analyze, Flutter tests, CLI smoke, macOS build, schema/secret scans.

## 7. Tasks

1. Implement contracts and projection; verify Core tests.
2. Implement control and skill invariants; verify failure/idempotency tests.
3. Implement CLI and Flutter shell; verify widget test and macOS build.
4. Add portable schema, CI, and packaging foundations; verify static scans.
5. Commit and push to the approved private remote after inspection.

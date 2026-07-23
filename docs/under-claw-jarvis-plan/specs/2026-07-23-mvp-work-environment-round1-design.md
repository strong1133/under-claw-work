# MVP work environment Round 1 design (2026-07-23)

## 1. Requirements and success criteria

`under-claw-work` is a provider-neutral work environment and skill collection,
not an Agent. It must run standalone on macOS and attach to an existing Hermes
Agent on remote Linux.

- Canonical CRUD, prompt revisions, all controls, claims, invocation audit and
  context links rebuild after SQLite deletion/corruption.
  `[verify: deterministic Core tests]`
- Two Git clones demonstrate fast-forward sync, stale-head rejection, offline
  status and conflict diagnostics.
  `[verify: local bare-remote integration test]`
- Flutter exposes the MVP management flow through Core rather than direct
  SQLite writes.
  `[verify: widget tests and macOS build]`
- One entry skill drives the three independent skills and persists nested
  evidence. A process contract test must not be represented as live Agent E2E.
  `[verify: executable adapter and invocation tree tests]`
- A headless bootstrap installs Core plus four skills into the documented
  Hermes boundary and removes only manifest-owned files.
  `[verify: isolated HOME/HERMES_HOME install/remove smoke]`
- Shared password login remains blocked while provider selection is pending;
  MVP relies on existing GitHub/SSH repository access and OS session security.
  `[verify: auth and leakage tests]`

### Brownfield comparison

| Requirement | Current HEAD | Round 1 correction |
|---|---|---|
| Git canonical graph | generic entities and Task YAML | typed required fields, canonical audit/context |
| Disposable SQLite | broad rebuild | remove SQLite-only execution results |
| Collaboration | init/clone | sync state, optimistic head, conflict result |
| Lifecycle | start only | five controls, dispositions, claim lease |
| Runtime | fake nested result | process adapter contract and persistent tree |
| GUI | setup/list/start | Task editing, approval, controls, audit |
| Hermes | marked unvalidated | upstream-native skill location/invocation contract |
| Distribution | source CI | bootstrap, ownership manifest, checksums, artifacts |

## 2. Adopted approach and rationale

Keep the existing single Dart Core boundary and add small canonical-first
services. Use Git CLI through a replaceable process boundary for MVP because it
is already the repository transport used by Hermes and GitHub; distribution
must either bundle it or verify the host-provided executable explicitly.

Hermes current upstream main (observed revision
`de5ece994415276d215976836161f871f1d6d8f5`) defines:

- skills under `${HERMES_HOME:-~/.hermes}/skills/`;
- native `hermes skills` install/list/update/uninstall/audit commands;
- deterministic loading through
  `hermes chat -s under-claw-work-plan -q "<task>"`;
- `/under-claw-work-plan` and `skill_view` inside interactive sessions.

The adapter will not modify Hermes Core. It installs four independent skill
trees and invokes only `under-claw-work-plan`. That skill explicitly loads the
other three and records each stage through `worklog`; a Hermes bundle by itself
is not accepted as orchestration evidence.

Rejected alternatives:

- custom password/verifier protocol: unsafe and prohibited;
- SQLite or stdout as execution authority: neither is durable/rebuildable;
- a Hermes project plugin as the default: project plugins are disabled by
  default and a skill plus terminal Core is sufficient for MVP;
- `skills.external_dirs` as default release installation: shadowing and
  writable external directories weaken ownership guarantees.

## 3. Change scope and files

- `lib/core/`: canonical validation, Task repository, controls, claims, Git
  sync, context packing, executable/Hermes adapters and durable orchestration.
- `lib/main.dart`, `bin/worklog.dart`: shared CRUD/control/sync interfaces.
- `workdb/schemas/`: normative MVP schemas.
- `skills/`: four independent release skill trees and lock manifest.
- `packaging/`, `tool/`, `.github/`: bootstrap, uninstall, contract smoke,
  checksums and unsigned test artifacts.
- `docs/`: current Hermes evidence, limitations and operator runbooks.

The source planning repository is not changed. No password provider is added.

## 4. Contracts

```text
CanonicalRepository.compareAndCreate(entity, expectedHead?)
TaskRepository.saveDraft / saveMeta / approveMeta
ControlService.request(command, operationId, runId?)
ClaimService.acquire / heartbeat / release / takeoverExpired
GitSyncService.status / pull / commitAndPush(expectedHead)
ProcessRunnerAdapter.invokeOrchestration(root)
HermesRunnerAdapter -> hermes chat -s under-claw-work-plan -q input
```

Every successful runtime stage writes immutable `SKI-` invocation entities and
an `EVT-` result before projection rebuild. stdout is diagnostic only.

## 5. Independent agreement

### Agreement

- Standalone Core plus native Hermes skill integration is the correct boundary;
  `under-claw-work` is not another Agent.
- The four skills stay independent and `under-claw-work-plan` is the only public
  Task entry.
- Hermes support must be version-pinned, checksum-verified and distinguished
  between process contract, isolated host smoke and live remote E2E.
- Git canonical files, not SQLite or Hermes stdout, determine recovery.

### Divergence table

| Issue | Implementer view | Hermes research view | Decision |
|---|---|---|---|
| Hermes boundary | unknown pending official evidence | native skills path and CLI are documented | adopt native skills CLI/path with a version gate |
| Plugin | possible adapter mechanism | unnecessary for MVP | no plugin; retain future extension note |
| External dirs | convenient shared tree | mutable/shadowable | do not use as default |

### Open assumptions

- A live remote Hermes binary/profile is not currently proven available.
  Contract and isolated CLI smoke are labelled separately until remote evidence
  exists.
- Release signing credentials are external; unsigned test artifacts are
  explicitly labelled.
- The exact Hermes minimum released version remains a packaging input; the
  verified main revision is recorded meanwhile.

## 6. Verification

1. format, analyze, unit/widget tests and macOS build;
2. SQLite deletion and invalid-database automatic rebuild;
3. two-clone Git sync/stale-head/conflict contract;
4. concurrent claim, TTL/takeover and idempotent controls;
5. executable adapter malformed/nonzero/timeout/recovery tests;
6. isolated Hermes skill discovery/invocation contract and honest live flag;
7. bootstrap/reinstall/uninstall ownership smoke;
8. migration dry run and repository/artifact/log secret scans.

## 7. Tasks

1. Harden canonical Task/control/claim/runtime services and tests.
2. Add Git collaboration and recovery tests.
3. Expand Flutter and CLI MVP management surfaces.
4. Package the pinned four-skill bundle and Hermes adapter contract.
5. Add manifest bootstrap/uninstall and CI artifact workflow.
6. Run all acceptance evidence, update docs, scan, commit and push.

## Primary Hermes sources

- <https://github.com/NousResearch/hermes-agent/blob/main/website/docs/guides/work-with-skills.md>
- <https://github.com/NousResearch/hermes-agent/blob/main/website/docs/user-guide/features/skills.md>
- <https://github.com/NousResearch/hermes-agent/blob/main/website/docs/reference/cli-commands.md>
- <https://github.com/NousResearch/hermes-agent/blob/main/website/docs/user-guide/features/plugins.md>
- <https://github.com/NousResearch/hermes-agent/blob/main/tests/hermes_cli/test_chat_skills_flag.py>
- <https://github.com/NousResearch/hermes-agent/blob/main/hermes_cli/main.py>
- <https://github.com/NousResearch/hermes-agent/blob/main/tools/skills_tool.py>
- <https://github.com/NousResearch/hermes-agent/blob/main/agent/skill_utils.py>

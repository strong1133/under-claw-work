# Round 1 implementer understanding draft

Status: `[DRAFT_READY]`

## Requirement summary

Turn the current vertical slice into an honestly installable, provider-neutral
work environment and four-skill bundle: native Flutter on the Mac, Core CLI
inside an existing Hermes Agent on Linux, with the user's own Git repository as
canonical storage.

## Verifiable success criteria

- Core CRUD and Task prompt approval/control flows survive deletion or
  corruption of SQLite because every durable result is canonical.
- A two-clone Git test demonstrates ordinary sync, stale-head rejection and
  conflict reporting without destructive merge behavior.
- Start is idempotent; all five controls, immutable dispositions, expiring
  claims, heartbeat and takeover have deterministic tests.
- The one public orchestration entrypoint invokes a real adapter process and
  persists its nested invocation/result tree. A synthetic trace is labelled as
  a contract fixture, not a live Agent execution.
- Flutter exposes entity/task creation and editing, Prompt Draft/Meta approval,
  control requests, status/audit and repository setup through Core APIs.
- macOS and Linux bootstrap/uninstall scripts operate only on manifest-owned
  paths; checksums and a four-skill bundle are verifiable.
- Hermes support uses current upstream extension documentation and a contract
  fixture if a live Hermes runtime is unavailable.
- No shared-password protocol is invented. MVP uses existing Git/SSH access and
  the local OS session lock while provider selection remains blocked.

## Current code map and affected boundaries

- `lib/core`: portable canonical repository, projection, setup, control and a
  trace-validating but mock-oriented pipeline.
- `lib/main.dart`: setup, Task list/detail, start-only GUI.
- `bin/worklog.dart`: setup/init/list/doctor only.
- `skills/under-claw-work-plan`: real single-entry contract exists; the other
  three pinned bundle members and host ownership lifecycle do not.
- `packaging`, `.github`: manifest example and 3-OS source build CI exist; no
  bootstrap/uninstaller or artifact checksums.
- `workdb/schemas`: Task and pending auth schemas only; most normative entity,
  control, claim, event and invocation contracts are absent.

## Brownfield three-way comparison

| Original intent | Current implementation | Correction required |
|---|---|---|
| Git canonical graph | Generic entities plus Task codec | Typed validation, prompt revisions, canonical audit and context links |
| Disposable SQLite | Entity/control rebuild exists | Invocation/knowledge audit must no longer be SQLite-only |
| Multi-environment sync | Git init/clone only | fetch/pull/push, optimistic head gate, offline/conflict status |
| Task lifecycle | start only | all controls, disposition lifecycle, claim lease/idempotency |
| Four-skill runtime | one skill plus fake trace tests | owned bundle and executable adapter contract |
| Flutter workspace | setup/list/start | MVP CRUD, prompt approval, controls, audit |
| Hermes | explicitly unsupported | upstream-verified adapter boundary and contract smoke |
| Easy install/remove | CI source build only | manifest-driven bootstrap/uninstall and artifact workflow |

Current implementation meets roughly one third of the required MVP foundation;
the correction should preserve its Dart Core architecture while replacing
projection-only and mock-only claims.

## Constraints and open questions

- The source planning repository is read-only.
- No live Hermes E2E may be claimed unless the actual runtime is installed and
  executed.
- A Git executable may exist on development hosts, but acceptance says end
  users should not install it separately; packaged artifact strategy must state
  whether Git is bundled or supplied by the host.
- Code signing/notarization can remain a credential gate; unsigned artifacts
  must be labelled.
- Shared repository password stays unavailable until a reviewed provider is
  selected.

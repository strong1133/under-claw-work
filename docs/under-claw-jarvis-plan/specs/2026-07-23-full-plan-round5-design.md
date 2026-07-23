# Full plan round 5 design (2026-07-23)

## 1. Requirements and success criteria

This is the final convergence round over the existing implementation. Preserve
rounds 1–4 and close the highest-risk executable gaps:

1. One canonical ID/field contract passes schema, codec, runtime validation and
   projection reconstruction. `[verify: contract fixture test]`
2. Generated Task candidates require objective/evidence, are deduplicated, and
   can be created from a completed run then accepted into the normal Draft →
   Meta pipeline. `[verify: candidate pipeline E2E]`
3. Legacy import requires an explicit CLI approval, can be rolled back, retains
   legacy state/relations, and never records an absolute source root.
   `[verify: migration CLI/service E2E]`
4. Uninstall supports app-only, runtime and full modes, remains manifest-scoped,
   and full removal requires explicit confirmation of exact paths.
   `[verify: isolated HOME shell smoke]`
5. Every `ProjectionStore.rebuild()` call uses the atomic lifecycle and a
   corrupt/deleted SQLite database self-recovers from canonical data.
   `[verify: lifecycle corruption E2E]`

Brownfield comparison: the required services and schemas exist, but operation
IDs disagree (`OP`/`OPR`), Claim validation disagrees with persisted fields,
candidate generation is manual-only, migration approval/rollback are not
exposed by CLI and leak the absolute source root, uninstall has one mode, and
two independent projection rebuild implementations exist.

## 2. Adopted approach and rationale

Adopt surgical convergence around existing Dart Core. Keep YAML/Markdown as the
canonical store and make SQLite strictly replaceable. Standardize operation IDs
on `OPR-`, because that is the declared operation schema and avoids introducing
a second entity meaning. Candidate generation remains deterministic and policy
gated; no model-specific generator is embedded. Migration remains copy-only and
rollback deletes only Tasks carrying the recorded legacy ID.

Rejected alternative: adding a new database/server or a general JSON Schema
engine in this round. It would not close the executable product flow and would
increase installation surface. The runtime validator remains the explicitly
documented normative acceptance boundary.

## 3. Change scope and files

- Core contracts/projection/candidates/migration:
  `lib/core/`, `workdb/schemas/`.
- CLI acceptance surface: `bin/worklog.dart`.
- Manifest-scoped removal: `packaging/uninstall.sh`.
- Deterministic evidence: `test/round5_core_test.dart`,
  `tool/round5_smoke.sh`.
- No authentication protocol invention, release signing, external deployment,
  repository push, or deletion of user data.

## 4. Cross-project contract impact

`operation_id` is `OPR-*` in schema and runtime. Claim uses
`task_id`, `run_id`, `environment_id`, heartbeat/expiry and status; it does not
pretend to own an Operation field. Control disposition remains an immutable
`EVT-*` keyed by `request_id`.

CLI adds:

```text
migrate-import <workspace> <legacy-path> <domain> <milestone> <environment> --approve
migrate-rollback <workspace> <import-id>
task-candidate-list <workspace>
```

Uninstall adds `--mode app|runtime|full`, with `--confirm-full <install-root>`
required for full removal.

## 5. Risks and unresolved assumptions

- Full repository authentication, remote compare-and-create and signed clean-VM
  installers remain honest release gates; no custom cryptography is added.
- A real Agent model may propose richer candidates. Core accepts only validated
  candidate data and does not bind to that provider.
- Shell deletion tests run only inside a temporary HOME.

## 6. Verification

Run Dart formatting, Flutter analyze/test, CLI build, macOS build, secret scan,
diff check, and isolated lifecycle/install/uninstall smoke. A corrupt SQLite
file must be reconstructed and migration reports must contain no absolute
legacy source path.

## 7. Tasks

1. Unify canonical ID/field contracts and add fixture coverage.
2. Connect candidate creation/acceptance to completed execution evidence.
3. Add approved import/rollback CLI and sanitized reports.
4. Route projection rebuild through lifecycle with recovery.
5. Add three safe uninstall modes and isolated smoke verification.
6. Run the complete verification matrix and hand results to the independent
   loop reviewer.

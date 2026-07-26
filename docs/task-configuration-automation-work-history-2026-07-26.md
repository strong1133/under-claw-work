# Task configuration and automation work history — 2026-07-26

## Purpose

This change extends a canonical Task from a Draft/Meta container into a portable,
configurable work unit. A Task can now record how it is scoped, which Projects it
relates to, where it may run, which portable model selections it needs, how it is
processed, and how generated child or related Tasks should be handled.

This document records the implementation published by the same commit as this
file. It intentionally distinguishes the implemented contract from follow-up
hardening work.

## Requirements captured

- Domain and Milestone are optional Task anchors.
- A Milestone cannot be selected without its owning Domain.
- A Task can select multiple canonical Projects.
- A Task can select multiple target Environments.
- A Task stores portable model selection keys; actual provider/model bindings
  remain host-local under `.worklog`.
- Processing can be manual or automatic.
- A Draft-only Task can explicitly request Meta Prompt generation.
- Task status determines Meta-generation and execution eligibility.
- Tasks can have one parent and multiple related Tasks.
- Automatic execution may propose or create child and related Tasks according to
  Task policy, without bypassing Meta Prompt approval.

## Canonical and runtime design

### Optional scope

Task schema version 3 writes `domain_id` and `milestone_id` as nullable YAML
values. The repository accepts these combinations:

1. no Domain and no Milestone;
2. Domain only;
3. Domain and a Milestone owned by that Domain.

Milestone-only scope is rejected. Supplied Domain, Milestone, and Project IDs are
validated against active canonical entities. An unscoped Task may still select
explicit Projects; this does not turn the Task into a Domain-scoped Task.

### Portable Task configuration

Canonical Task YAML stores only portable data:

- `project_ids`;
- `target_environment_ids`;
- `model_selection_keys`;
- `processing_mode`;
- `parent_task_id` and `related_task_ids`;
- child/related generation policy and maximum generation depth.

Actual repository paths, adapter commands, provider names, model names, and
credentials are not stored in Task YAML. `HostBindingRegistry` resolves a
portable model key for one selected Environment immediately before execution.
Missing Environment/model bindings fail closed.

### Prompt lifecycle

The Task lifecycle now includes `writing`, `metaRequested`, and `metaReview` in
addition to the existing execution states.

- Editing a Draft returns the Task to `writing` and makes prior approval stale.
- A Meta request requires a non-empty Draft.
- Auto Meta processes only an explicitly automatic, Meta-requested Task.
- Generated Meta is recorded as pending review.
- Approval of a Meta Prompt for the exact current Draft transitions the Task to
  `ready`.
- Automatic processing never approves a Meta Prompt.

### Execution and generation

A start request chooses exactly one Environment from the Task's allowed list.
The worker revalidates the Task Draft revision, selected Environment, host-local
model resolution, scope, approval, ownership, and existing execution fencing
before invoking the runner. Resolved model data is propagated as runtime
invocation metadata and adapter input rather than canonical Task data.

Successful orchestration can emit `child` or `related` Task candidates. Accepted
Tasks inherit the parent's explicit scope configuration, Projects,
Environments, portable model keys, and processing policy. Generated Tasks start
at `writing` or `metaRequested` and remain subject to the same Meta approval
gate. Generation depth and duplicate fingerprints are enforced.

## User surfaces

### Desktop UI

The Task editor now exposes:

- optional Domain and Milestone selectors;
- multi-select Project, Environment, model-key, and related-Task controls;
- parent Task selection;
- manual/automatic processing;
- Meta request action and lifecycle status;
- child/related generation, auto-accept, and depth controls;
- execution Environment selection when more than one target is configured.

### CLI and watcher

The CLI adds configurable Task creation/configuration, explicit Meta request,
Task automation scheduling, and Environment-aware start routing. The packaged
Auto Meta watcher also invokes the automatic-ready Task scheduler after the
Meta pass.

## Persistence and compatibility

- Task codec write version: 3.
- Task v1/v2 files remain readable and are normalized in memory.
- Legacy `target_environment` is lifted into a singleton compatibility view.
- Reading or projection rebuilding does not bulk-rewrite canonical Task files.
- SQLite projection format: 2.
- Projection rows include portable Task configuration and relation fields.
- SQLite remains disposable and rebuildable from Git-canonical YAML.

## Main implementation files

- `lib/core/models.dart`
- `lib/core/task_codec.dart`
- `lib/core/task_repository.dart`
- `lib/core/schema_validator.dart`
- `lib/core/host_binding_registry.dart`
- `lib/core/control_service.dart`
- `lib/core/execution_worker.dart`
- `lib/core/auto_meta_worker.dart`
- `lib/core/task_automation_service.dart`
- `lib/core/task_candidate_service.dart`
- `lib/core/skill_pipeline.dart`
- `lib/core/process_runner_adapter.dart`
- `lib/core/scope_context_resolver.dart`
- `lib/core/context_builder.dart`
- `lib/core/projection.dart`
- `lib/core/projection_lifecycle.dart`
- `bin/worklog.dart`
- `lib/main.dart`
- `lib/ui/task_configuration_dialog.dart`
- `packaging/auto-meta-watch.sh`
- `workdb/schemas/task.schema.yaml`
- `workdb/schemas/task-candidate.schema.yaml`

## Verification evidence

The publication gate for this commit includes:

- `dart format --output=none --set-exit-if-changed .` — passed;
- `flutter analyze` — passed with no issues;
- focused Task configuration tests — passed;
- Auto Meta worker tests — passed;
- desktop multi-Environment/model selection widget test — passed;
- orchestration child/related auto-accept integration test — passed;
- 36 non-golden test files, 274 tests — passed;
- functionality/accessibility tests in the four golden-bearing UI files, 17
  tests — passed;
- repository secret scan — passed;
- independent exact-diff review — required by the `[verified]` commit gate.

Final publication results:

- Full Flutter command: **291 passed, 5 golden pixel comparisons failed**.
- Baseline comparison: the same five golden failures, with identical pixel
  percentages and counts, reproduce in a clean detached worktree at
  `7a4becdf754bbeca6670298c7a7396d9bf57ae88`; they are not introduced by this
  change. No golden images were rewritten.
- Non-golden suite: **274/274 passed** across 36 files.
- Additional functionality/accessibility tests in golden-bearing files:
  **17/17 passed**.
- Secret scan: **passed** using `tool/secret_scan.sh`.
- Independent exact-diff review: a `[verified]` commit is permitted only after
  the staged tree receives a passing verdict.

## Known limitations and follow-up hardening

These limits are recorded explicitly; this commit must not be interpreted as
proof that every future distributed automation policy is complete.

1. Control requests fence the current Draft revision, but a dedicated immutable
   Task-configuration revision/hash is not yet part of the canonical Task
   contract. Execution configuration edits made after a request need a stronger
   stale-request fence.
2. Automatic-ready scheduling checks canonical control requests for duplicates,
   but deterministic cross-clone scheduling/lease semantics need a hostile
   concurrency test and a Git-remote idempotency contract.
3. Model selections are portable keys resolved to host-local strings. A future
   revision should make model roles and `{adapter_id, model_id}` structure
   explicit and verify the selected execution adapter capability for each role.
4. Child/related generation uses compatible booleans. A per-relation
   `disabled | propose | autoCreate` policy would be clearer for future policy
   expansion.
5. `related_task_ids` is canonical for this Task flow; relation-sidecar symmetry
   and migration still require a single-authority decision.
6. Notion mirroring and legacy import do not yet expose every new Task v3 field.
7. Linux local verification does not replace native macOS and Windows CI.

## Security boundary

No credentials, provider tokens, local host paths, actual provider/model names,
or secure-store values are introduced into canonical Task data or this work
history. Host-local bindings remain ignored runtime projection. Existing
approval, adapter verification, Git fencing, and secret-handling rules continue
to apply.

# ADR 0002: Environment identity split, registry file format, and provenance matching

Status: accepted

## Context

The initial vertical slice stored the environment registry as
`workdb/config/environments.json` and keyed environment de-duplication on the
user-supplied `name`. Two problems followed:

1. A JSON registry violates invariant 1 (Git의 YAML·Markdown만 영구 정본이다):
   the permanent canonical form must be YAML or Markdown.
2. Using the editable display name as the identity key meant renaming an
   environment could mint a duplicate `ENV-` id or break Task/Run/Event/Claim
   references.

Separately, 추가요구 2 (자료매칭) and 추가요구 3 (다중 agent 통합기억) need a
first-class, provenance-tracked link between Knowledge/Reference and
Domain/Milestone/Objective/Task that survives a projection rebuild.

## Decision

### Environment identity and registry

- The canonical environment registry is the YAML document
  `workdb/config/environments.yaml`, co-located with the existing
  `repository-auth.yaml` and `skill-pipeline.yaml` config registries. A
  pre-existing `environments.json` is still **read** for backward
  compatibility and is never rewritten, so no destructive migration occurs.
- Identity is split: `id` (immutable ULID, `ENV-…`) and `machine_key`
  (immutable, salted host hash `MK-…`) are the identity; `alias` is a
  free-form, user-editable display name that is never an identity key. `name`
  is retained only for legacy reads.
- Registration is idempotent by `machine_key`. A legacy name-only record is
  safely promoted once (id preserved, no duplicate ENV) when its host is first
  detected. Salt/reinstall loss is recovered through an explicit `relink`,
  which rotates `machine_key` onto the existing id and records the superseded
  key in `previous_machine_keys` (immutable audit).
- Registry writes are lock-guarded (exclusive lock file) and atomic (temp +
  rename) to prevent lost updates under concurrent management.

### Agent registry

- The canonical Agent registry is `workdb/config/agents.yaml`. Each Agent
  references its Environment by the immutable `environment_id` (`ENV-…`), so an
  alias rename never breaks the binding. The existing `agent.schema.yaml`
  `adapter` field is retained as an optional, backward-compatible property.

### Provenance matching (Match entity)

- A new canonical entity `Match` (`MAT-…`, stored per file under
  `workdb/matches/{id}.yaml`) records a many-to-many link between a subject
  (Knowledge/Reference) and a target (Domain/Milestone/Objective/Task).
- Each match carries `match_mode` (manual/agent/hybrid), `actor`, timestamps,
  `evidence`, `confidence`, `source`, and a `review_state`
  (proposed/approved/rejected/revoked). Review transitions append to an
  append-only `history` list and emit an immutable `match_reviewed` Event.
- Referential integrity is enforced by the existing canonical relation fields
  (`knowledge_ids`/`reference_ids`/`domain_id`/`milestone_id`/`objective_ids`/
  `scope.task_ids`), so matches and their references are rebuilt from Git alone.

## Consequences

- The permanent canonical store stays YAML/Markdown (invariant 1 upheld).
- The runtime acceptance boundary (`WorklogContractValidator`) now validates
  Environment, Agent, and Match records, and whole-graph validation covers the
  Environment ↔ Agent link. Schema `.yaml` files remain portable documentation.
- No Agent/model/OS/Notion identifier is hard-coded in any canonical schema.
- Requirement 4 (Flutter Orca/Warp + D2Coding) and requirement 5 (Notion
  adapter) remain out of scope and tracked as follow-up tasks.

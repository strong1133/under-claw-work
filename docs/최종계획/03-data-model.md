# 정본 데이터 모델

<!-- 최종 계획 문서 -->

## ID

모든 엔티티는 `타입 prefix + ULID`를 사용한다.

| 엔티티 | Prefix |
|---|---|
| Domain | `DOM-` |
| Milestone | `MLS-` |
| Objective | `OBJ-` |
| Task | `TSK-` |
| Knowledge | `KNW-` |
| Reference | `REF-` |
| Event | `EVT-` |
| Environment | `ENV-` |
| Agent | `AGT-` |
| Run | `RUN-` |
| Claim | `CLM-` |
| ControlRequest | `CTR-` |
| Operation | `OPR-` |
| SkillInvocation | `SKI-` |

ID는 중앙 DB 없이 각 환경에서 생성하며 한번 발급하면 변경하지 않는다. 기존 PT ID는 `legacy_ids`로 보존한다.

## Domain

경로:

```text
workdb/domains/{domain_id}/domain.md
```

예시:

```yaml
---
schema_version: 1
id: DOM-...
type: domain
name: lawtomatic
title: 로토매틱
status: active
owners:
  - user:example
default_environment_selector:
  preferred: ENV-...
objective_ids:
  - OBJ-...
knowledge_ids:
  - KNW-...
reference_ids:
  - REF-...
created_at: 2026-07-23T10:00:00+09:00
updated_at: 2026-07-23T10:00:00+09:00
---

Domain 설명
```

## Milestone

경로:

```text
workdb/milestones/{milestone_id}/milestone.md
```

핵심 필드:

```yaml
schema_version: 1
id: MLS-...
type: milestone
domain_id: DOM-...
title: 전자소송 연동 안정화
status: active
priority: high
target_date: null
objective_ids:
  - OBJ-...
success_criteria:
  - 관련 핵심 테스트가 통과한다.
knowledge_ids:
  - KNW-...
reference_ids:
  - REF-...
created_at: ...
updated_at: ...
```

파생 Task는 반드시 연결된 Objective ID 중 하나 이상을 생성 근거로 지정한다.

## Objective

경로:

```text
workdb/objectives/{objective_id}.md
```

예시:

```yaml
---
schema_version: 1
id: OBJ-...
type: objective
scope:
  domain_id: DOM-...
  milestone_id: MLS-...
title: 전자소송 사건 목록 API 계약을 통합한다
status: active
priority: high
success_criteria:
  - 공통 응답 계약 테스트가 통과한다.
knowledge_ids:
  - KNW-...
reference_ids:
  - REF-...
parent_objective_ids: []
created_at: ...
updated_at: ...
---

Agent가 Task를 생성하고 완료 여부를 평가할 때 사용할 목표 설명
```

규칙:

- `domain_id`는 필수다.
- Domain 수준 목표는 `milestone_id: null`이다.
- Milestone 목표는 해당 `milestone_id`를 가진다.
- Milestone 목표는 필요하면 Domain 목표를 `parent_objective_ids`로 연결한다.
- Objective를 archive해도 기존 Task의 생성 근거 관계는 보존한다.

## Task

경로:

```text
workdb/tasks/{task_id}/
├─ task.yaml
├─ prompt.draft.md
├─ prompt.meta.md
├─ relations.yaml
└─ artifacts.md
```

`task.yaml` 핵심 스키마:

```yaml
schema_version: 1
id: TSK-...
type: task
domain_id: DOM-...
milestone_id: MLS-...
title: 사건 목록 응답에 당사자 지위 추가
status: ready
priority: high

prompt:
  draft_revision: 1
  meta_revision: 1
  meta_based_on_draft_revision: 1
  meta_status: approved

options:
  auto_create_derived_tasks: true
  auto_create_followup_tasks: false
  max_generation_depth: 2

execution:
  strategy: single_agent
  orchestration_pipeline: under_claw_default_v1
  environment_selector:
    allowed: []
    preferred: ENV-...
  required_capabilities:
    - git

generation:
  created_automatically: false
  parent_task_id: null
  aligned_objective_ids: []
  evidence_knowledge_ids: []
  source_reference_ids: []
  generation_depth: 0
  fingerprint: null

created_by:
  actor_type: user
  actor_id: user:example
created_at: ...
updated_at: ...
legacy_ids: []
```

## Prompt 문서

Prompt 파일 frontmatter:

```yaml
---
schema_version: 1
task_id: TSK-...
prompt_type: draft
revision: 1
created_by:
  actor_type: user
  actor_id: user:example
created_at: ...
---
```

Meta Prompt에는 추가 필드가 필요하다.

```yaml
prompt_type: meta
revision: 1
based_on_draft_revision: 1
approval_status: approved
approved_by: user:example
approved_at: ...
generator:
  kind: skill
  name: under-claw-meta-prompt
  bundle_version: ...
  invocation_id: SKI-...
```

과거 revision은 Git history로 보존한다. 자주 비교하거나 복원해야 할 필요가 확인되면 `revisions/`에 immutable snapshot을 추가한다.

## Knowledge

경로:

```text
workdb/knowledge/{knowledge_id}.md
```

```yaml
---
schema_version: 1
id: KNW-...
type: knowledge
kind: confirmed_fact
scope:
  domain_ids: [DOM-...]
  milestone_ids: [MLS-...]
  task_ids: [TSK-...]
  run_ids: [RUN-...]
concepts:
  - ecfs
confidence: confirmed
relations:
  supports: []
  contradicts: []
  supersedes: []
  derived_from: []
source_refs: []
created_at: ...
updated_at: ...
---

AI 검색과 context pack에 최적화된 원자적 내용
```

허용 `kind`:

- `requirement`
- `confirmed_fact`
- `assumption`
- `open_question`
- `decision`
- `constraint`
- `progress`
- `failure`
- `procedure`
- `handoff_summary`

Domain·Milestone의 사전 지식도 같은 Knowledge 엔티티를 사용한다. Task 실행 중 생성된 기억과 구별할 필요가 있으면 `origin`을 사용한다.

```yaml
origin:
  kind: user_authored
  actor_id: user:example
```

허용 origin 예:

- `user_authored`
- `agent_discovered`
- `reference_extracted`
- `task_result`
- `imported`

## Reference

경로:

```text
workdb/references/{reference_id}.md
```

예시:

```yaml
---
schema_version: 1
id: REF-...
type: reference
title: 전자소송 진행 사건 API 연동 매뉴얼
reference_type: repository_document
scope:
  domain_ids:
    - DOM-...
  milestone_ids:
    - MLS-...
locator:
  kind: repo_relative_path
  value: docs/manual.md
content_hash: null
status: active
knowledge_ids:
  - KNW-...
created_at: ...
updated_at: ...
---

자료의 용도, 읽을 범위와 주의사항
```

허용 `reference_type` 예:

- `repository_document`
- `attachment`
- `public_url`
- `internal_url_masked`
- `source_repository`
- `issue_or_pr`
- `meeting_note`
- `specification`

`locator.kind` 예:

- `repo_relative_path`
- `workspace_relative_path`
- `url`
- `external_id`
- `artifact_id`

보안 규칙:

- 환경별 절대경로보다 저장소 상대경로와 논리적 workspace path를 우선한다.
- credential이 포함된 URL을 저장하지 않는다.
- 내부 URL과 고객 식별정보는 저장소 보안 규칙에 따라 마스킹한다.
- 대용량 binary는 Git에 직접 넣기 전에 크기 정책을 확인하고 artifact metadata로 연결한다.
- Reference는 원자료의 위치이며, Agent가 신뢰할 수 있는 사실로 사용하려면 추출한 Knowledge와 출처 관계를 남긴다.

## Event

Event는 append-only다.

경로:

```text
workdb/events/{YYYY}/{MM}/{event_id}.yaml
```

```yaml
schema_version: 1
id: EVT-...
type: event
event_type: task_status_changed
task_id: TSK-...
run_id: RUN-...
actor:
  actor_type: agent
  actor_id: AGT-...
environment_id: ENV-...
occurred_at: ...
payload:
  from: ready
  to: claimed
```

기존 Event 수정은 금지하고 정정 Event를 추가한다.

## ControlRequest

원격 실행 상태를 GUI가 직접 덮어쓰지 않도록 제어 명령을 독립 정본으로 기록한다.

경로:

```text
workdb/control-requests/{YYYY}/{MM}/{control_request_id}.yaml
```

```yaml
schema_version: 1
id: CTR-...
type: control_request
operation_id: OPR-...
task_id: TSK-...
run_id: null
command: start
expected_task_revision: 7
target_environment_id: ENV-...
target_agent_id: null
requested_by:
  actor_type: user
  actor_id: user:example
requested_from_environment_id: ENV-...
idempotency_key: ...
reason: null
requested_at: ...
```

허용 `command`:

- `start`
- `pause`
- `resume`
- `cancel`
- `complete`

규칙:

- ControlRequest는 생성 후 어떤 필드도 수정하지 않는 immutable append-only 정본이다.
- 같은 `idempotency_key`는 한 번만 처리한다.
- `operation_id`는 하나의 시작 시도와 모든 복구 재진입에서 동일하다.
- `expected_task_revision`이 다르면 Core가 요청 생성을 거부한다.
- `start`만 생성 시 `run_id: null`을 허용한다. 나머지 명령은 대상 `run_id`가 필수다.
- `target_environment_id`는 모든 명령에 필수다. `start`의 `target_agent_id`는 자동 배정일 때만 `null`이며, 나머지 명령은 현재 Run 소유 Agent가 필수다.
- Task의 `요청됨`, `ACK됨` 상태는 Request와 Disposition을 읽어 만든 projection이며 Request에 기록하지 않는다.

## ControlDisposition Event

ACK, reject, withdraw, expire와 supersede는 Request를 수정하지 않고 별도 immutable Event로 기록한다.

경로:

```text
workdb/control-dispositions/{request_id}.yaml
```

```yaml
schema_version: 1
id: EVT-...
type: event
event_type: control_disposition
request_id: CTR-...
operation_id: OPR-...
disposition: acknowledged
run_id: RUN-...
actor:
  actor_type: agent
  actor_id: AGT-...
environment_id: ENV-...
reason_code: null
occurred_at: ...
```

규칙:

- request당 위 고정 경로의 Disposition은 하나만 존재한다.
- ACK, reject, withdraw, expire와 supersede 후보는 같은 경로에 remote compare-and-create를 시도하며 먼저 생성한 하나가 최종 승자다.
- Disposition도 생성 후 수정하지 않는다. 정정은 별도 정정 Event를 추가하되 원래 승자를 바꾸지 않는다.
- `acknowledged`는 지정 Agent 또는 claim 승자만 생성할 수 있다. `pause`, `resume`, `cancel`, `complete`는 해당 Run 소유 Agent만 ACK한다.
- `pause`와 `cancel` ACK는 안전 checkpoint 이후, `complete` ACK는 검수 gate 이후에만 생성한다.
- `withdraw_control_request(request_id, expected_disposition=absent, idempotency_key)`는 `withdrawn` Disposition 생성을 시도한다.
- 철회가 먼저 생성되면 이후 ACK는 `DISPOSITION_EXISTS`로 실패한다. ACK가 먼저 생성되면 철회도 같은 오류로 실패하며, 실행 중인 Run을 멈추려면 별도의 `cancel` Request를 만든다.
- 동일 철회 idempotency key 재요청은 최초 결과를 반환한다.

### start operation 복구와 재진입

`start`는 동일 `operation_id`를 사용해 다음 순서로 처리한다.

1. 대상 Agent가 `operation_id`와 미리 발급한 `reserved_run_id`를 포함한 Claim을 compare-and-create한다.
2. claim 승자만 `reserved_run_id`로 Run을 생성한다. Run의 `operation_id`에는 unique constraint를 적용한다.
3. Run이 준비되면 request 고정 경로에 `acknowledged` Disposition을 compare-and-create한다.
4. ACK Disposition을 읽은 projection이 Task를 `claimed`, 실행 시작 후 `in_progress`로 전이한다.

부분 상태 복구:

- Claim-only: 같은 `operation_id`와 `reserved_run_id`로 Run 생성을 재시도한다.
- Run-only: 새 Run을 만들지 않고 기존 Run으로 ACK Disposition 생성을 재시도한다.
- Disposition-only가 먼저 보이지만 Run이 아직 동기화되지 않음: projection을 보류하고 동일 `operation_id`의 Run을 기다린다.
- Run 생성 뒤 withdraw/reject Disposition이 경합에서 승리: Run을 `aborted_before_start`로 마감하고 Claim을 해제한다.
- Claim 만료 후 recovery Agent도 기존 `operation_id`와 `reserved_run_id`를 이어받는다. 새 Run ID를 발급하지 않는다.

`operation_id` unique lookup, `reserved_run_id`, fixed Disposition path의 조합으로 retry와 recovery 중 duplicate Run을 금지한다.

## SkillInvocation

모든 Task에서 세 스킬 사용 여부와 실행 근거를 추적한다. SkillInvocation은 Event payload 또는 별도 immutable 문서로 projection할 수 있으며 논리 스키마는 다음과 같다.

```yaml
schema_version: 1
id: SKI-...
type: skill_invocation
task_id: TSK-...
run_id: RUN-...
skill_id: under-claw-meta-prompt
bundle_version: ...
input_ref:
  kind: prompt_revision
  revision: 3
provider_adapter: generic
agent_id: AGT-...
started_at: ...
finished_at: ...
status: succeeded
result_ref: ...
```

`provider_adapter`는 실행 기록일 뿐 Task의 업무 의미나 schema를 특정 provider에 고정하지 않는다.

필수 실행 순서:

```text
under-claw-meta-prompt
→ under-claw-jarvis-plan-loop
→ under-claw-jarvis-plan (각 loop round)
```

## Repository auth policy

경로:

```text
workdb/config/repository-auth.yaml
```

```yaml
schema_version: 1
auth_policy_id: ...
policy_version: 1
mode: repository_password
provider_selection_status: pending_selection
verifier_provider: null
verifier_locator: null
kdf_policy:
  algorithm: argon2id
  parameter_profile: worklog-v1
updated_at: ...
```

이 예시는 구현 전 상태다. provider는 아직 선정되지 않았으며 `provider_selection_status: accepted` 전에는 repository bootstrap과 로그인을 구현하지 않는다. 선정 gate와 권장 challenge 계약의 normative source는 [로그인과 보안](06-security-auth.md)이다. 이 파일은 선정 후에도 공개 가능한 policy와 opaque locator만 담고 실제 password, verifier payload, token과 recovery secret은 넣지 않는다.

## Skill pipeline policy

경로:

```text
workdb/config/skill-pipeline.yaml
```

```yaml
schema_version: 1
pipeline_id: under_claw_default_v1
required:
  prompt_transform: under-claw-meta-prompt
  execution_loop: under-claw-jarvis-plan-loop
  round_implementation: under-claw-jarvis-plan
approval:
  meta_required: true
  loop_target_score: 9.5
fallback:
  missing_native_skill_host: generic_runner_adapter
```

skill source revision과 checksum은 설치 bundle manifest에 기록한다. 특정 Agent model 이름은 이 policy에 넣지 않는다.

## Environment registry

```yaml
schema_version: 1
environments:
  - id: ENV-...
    name: JSJ MacBook
    os: macos
    architecture: arm64
    kind: desktop
    status: active
    capabilities:
      - gui
      - git
      - docker
```

환경 목록은 코드 enum이 아닌 버전 관리 registry다. Schema 검증용 enum은 registry로부터 생성한다.

## Agent registry

```yaml
schema_version: 1
agents:
  - id: AGT-...
    name: Hermes Main
    kind: hermes
    environment_id: ENV-...
    status: active
```

## 관계

Task 관계:

- `blocked_by`
- `blocks`
- `derived_from`
- `follows`
- `related_to`
- `supersedes`
- `duplicates`
- `reopens`

Core는 역관계를 인덱스에 생성하고 의존성 순환을 차단한다.

# Task와 Multi-agent 워크플로

<!-- 최종 계획 문서 -->

## 상태

```text
draft
  ↓
meta_required
  ↓
ready
  ↓ start 요청 → 실제 상태 유지 (`start_requested`는 UI projection)
  ↓ 대상 Agent claim CAS + Run 생성 + ACK
claimed
  ↓
in_progress
  ├── pause 요청/ACK → paused ── resume 요청/ACK → in_progress
  ├── blocked
  ├── failed
  ├── cancelled
  └── completed
```

Core가 허용된 상태 전이만 수행한다. GUI나 Agent가 `task.yaml`을 직접 변경해 우회하지 않는다.

## Task 생성

1. Domain과 Milestone 존재 확인
2. 연결된 주요 Objective, 사전 Knowledge와 Reference 로드
3. Task가 기여할 Objective를 하나 이상 선택
4. ULID 기반 Task ID 발급
5. `task.yaml`과 `prompt.draft.md` 생성
6. 생성 근거 Knowledge와 Reference 기록
7. Draft가 비어 있지 않으면 `meta_required`
8. 생성 Event 기록
9. validation 후 commit

Agent 자동 생성 시 추가 조건:

- Domain 또는 Milestone의 Objective ID를 하나 이상 지정
- 생성 이유 기록
- 생성에 사용한 Knowledge와 Reference ID 기록
- parent Task 연결
- generation depth 제한
- fingerprint로 중복 차단

## Meta Prompt

실행 가능 조건:

```text
meta_status == approved
AND meta_based_on_draft_revision == draft_revision
```

Draft 수정 시:

1. Draft revision 증가
2. 기존 Meta를 `stale`로 표시
3. Task를 `meta_required`로 이동
4. 재생성 전 실행 차단

Meta 생성은 adapter 구조로 구현한다. 첫 adapter는 `under-claw-meta-prompt` 호환 방식으로 만들되 Core가 특정 Agent에 종속되지 않게 한다.

`under-claw-meta-prompt`는 이름을 포함한 명시적 invocation으로 실행한다. 일반 Agent prompt로 비슷하게 흉내 낸 결과는 승인 가능한 Meta로 인정하지 않는다. invocation ID와 bundle version을 Meta frontmatter와 Event에 기록한다.

## 필수 세 스킬 pipeline

모든 수동·자동 Task 처리는 다음 순서를 따른다.

```text
1. Draft 생성 또는 수정
2. under-claw-meta-prompt 명시적 호출
3. Meta diff 검토와 승인
4. under-claw-jarvis-plan-loop 명시적 호출
5. loop가 매 회차 under-claw-jarvis-plan 명시적 호출
6. 분리 reviewer gate 통과
7. 완료 또는 blocked/failed 기록
```

`under-claw-jarvis-plan-loop`가 내부에서 base plan을 호출하므로 Core가 base plan을 별도 선행 실행해 같은 작업을 중복 수행하지 않는다. 세 스킬이 맡는 책임과 provider adapter 계약은 [세 스킬 오케스트레이션](09-skill-orchestration.md)에 정의한다.

## Context pack

Task 실행 전에 Core가 다음을 순서대로 구성한다.

1. Domain 설명과 규칙
2. Domain의 주요 Objective, 사전 Knowledge와 Reference
3. Milestone의 주요 Objective, 사전 Knowledge와 Reference
4. Task가 기여하는 Objective와 성공 기준
5. Task 승인 Meta Prompt
6. 선행·관련 Task 요약
7. 직접 연결된 Knowledge
8. concept graph를 통해 확장된 중요 Knowledge
9. 필요한 Reference 원문 또는 허용된 발췌
10. 최근 Run과 handoff summary
11. 대상 저장소의 Agent 지침

토큰 예산을 초과하면 importance, relation distance, 최신성 기준으로 압축한다. 영구 정본은 수정하지 않고 실행용 pack만 압축한다.

Reference는 무조건 전체를 삽입하지 않는다. Objective와 Task에 지정된 읽기 범위, content hash, 최신성 및 보안 정책을 확인한 뒤 필요한 부분만 context pack에 포함한다.

## Execution claim

같은 Task의 중복 실행을 막기 위해 원격 claim을 사용한다.

```yaml
schema_version: 1
id: CLM-...
task_id: TSK-...
operation_id: OPR-...
reserved_run_id: RUN-...
agent_id: AGT-...
environment_id: ENV-...
claimed_at: ...
heartbeat_at: ...
expires_at: ...
base_commit: ...
```

점유 절차:

1. remote head 갱신
2. Task 상태, Meta와 선행 조건 확인
3. 만료되지 않은 claim 존재 여부 확인
4. GitHub API의 조건부 생성으로 claim 획득 시도
5. `409` 또는 `422` 충돌은 점유 실패로 처리
6. start operation이면 같은 `operation_id`와 `reserved_run_id`로 Run과 ACK Disposition 생성을 재진입 가능하게 처리
7. ACK Disposition 확인 후 Task를 `claimed`, 이어서 `in_progress`로 전이

Agent는 heartbeat를 갱신한다. 만료된 claim은 바로 탈취하지 않고 이전 Run 상태를 확인한 후 recovery Event와 함께 회수한다.

## GUI·CLI 제어 명령

GUI와 CLI는 같은 Core command를 사용한다.

| 사용자 명령 | 선행 상태 | 요청 ACK 후 상태 | 비고 |
|---|---|---|---|
| 시작 | `ready` | `claimed`, 이후 `in_progress` | pending 동안 실제 상태는 `ready`; 최신 승인 Meta와 pipeline 검증 필수 |
| 일시중지 | `in_progress` | `paused` | Agent 안전 checkpoint가 없으면 reject |
| 재개 | `paused` | `in_progress` | 동일 Run 소유 Agent가 ACK |
| 중단 | `claimed`, `in_progress`, `paused`, `blocked` | `cancelled` | 정리·checkpoint ACK 전에는 `cancel_requested` 표시 |
| 완료 | `in_progress`, `blocked` | `completed` | 검수 gate와 산출물 기록 필수 |

처리 순서:

1. Core가 expected Task revision과 권한, 상태 전이, 선행 조건을 검사한다.
2. `operation_id`, idempotency key, target Environment와 선택적 target Agent를 가진 immutable ControlRequest를 append한다. `start`만 Request의 `run_id: null`이고 다른 명령은 현재 Run ID가 필수다.
3. GUI는 Request와 Disposition projection으로 `요청 중`을 표시하며 Task의 실제 상태는 유지한다.
4. `start`는 지정 Agent 또는 target Environment의 claim compare-and-create 승자만 처리한다. 승자는 같은 `operation_id`로 Claim → reserved Run → ACK Disposition을 순서대로 생성한다.
5. 나머지 명령은 현재 Run 소유 Agent만 별도 immutable ACK 또는 reject ControlDisposition을 생성한다.
6. request별 고정 Disposition 경로의 remote compare-and-create를 먼저 성공한 ACK/reject/withdraw/expire/supersede 하나만 최종 결과다.
7. ACK Disposition 후에만 Task 실제 상태를 전이하고 다른 환경은 sync 후 같은 projection을 표시한다.

앱 강제 종료나 네트워크 단절이 있어도 같은 idempotency key와 `operation_id`로 재진입한다. Claim-only는 reserved Run을 생성하고, Run-only는 기존 Run으로 ACK Disposition을 생성하며, ACK Disposition만 먼저 보이면 Run 동기화까지 projection을 보류한다. Run은 `operation_id` unique constraint와 Claim의 `reserved_run_id`로 중복 생성을 막는다. Agent가 응답하지 않으면 Core는 Request를 수정하지 않고 `expired` Disposition 생성을 시도한다.

### 제어 요청 철회

아직 처리되지 않은 요청은 다음 Core 명령으로만 철회한다.

```text
withdraw_control_request(request_id, expected_disposition=absent, idempotency_key)
```

- Disposition이 아직 없는 Request만 철회할 수 있다.
- 철회와 Agent ACK가 경합하면 고정 Disposition 경로의 remote compare-and-create를 먼저 성공한 쪽이 승자다.
- 철회가 이기면 immutable `withdrawn` Disposition이 생기고 이후 ACK는 `DISPOSITION_EXISTS`로 거부된다.
- ACK가 이기면 철회도 `DISPOSITION_EXISTS`로 실패한다.
- 철회 재시도는 같은 idempotency key로 최초 결과를 반환한다.
- `withdraw_control_request`는 pending 명령을 취소할 뿐이다. 이미 시작된 Task/Run을 멈추는 `cancel`과 의미가 다르다.

## Edit lease

GUI에서 Prompt나 같은 구조화 필드를 편집할 때 짧은 edit lease를 사용한다.

- 읽기는 항상 허용
- Knowledge와 Event의 append는 별도 허용
- 실행 중인 Meta revision은 수정 금지
- 수정이 필요하면 새 Draft revision을 생성

## 실행 완료

Agent는 다음을 기록한다.

- 변경 내용과 산출물
- 실행한 검증과 결과
- 확인된 사실과 결정
- 남은 쟁점
- 실패 및 회피 방법
- 후속 작업 후보
- 대상 코드 저장소 commit 또는 변경 참조

완료 조건이 충족되면 `completed`로 전이한다. 재작업은 완료 Task를 되돌리지 않고 `reopens` 관계의 새 Task를 생성한다.

## 파생·후속 Task

자동 생성 전 검사:

1. 해당 Task option이 `true`
2. Domain 또는 Milestone Objective와 연결
3. Objective 달성에 필요한 이유를 설명
4. 사용한 Knowledge와 Reference를 근거로 연결
5. 최대 generation depth 이내
6. 동일 fingerprint 미존재
7. 원 Task 범위를 무의미하게 복제하지 않음

자동 생성된 Task는 기본적으로 `draft` 또는 `meta_required`이며 바로 실행하지 않는다. 정책에 따라 Meta 생성과 사용자 승인 단계를 거친다.

자동 처리 옵션이 활성화되어도 필수 세 스킬 pipeline은 생략하지 않는다. GUI는 다음 정책을 분리해 설정한다.

- 후보만 생성하고 사용자 승인 대기
- Draft와 Meta까지 자동 생성하고 Meta 승인 대기
- 사전 승인된 policy 범위에서 Meta 승인 후 자동 시작

자동 시작 정책도 Objective, Environment, generation depth, 최대 동시 실행 수와 허용 시간대를 제한해야 한다. 생성·승인·시작 주체와 근거를 Event에 기록한다.

## Git sync 실패

- 인증 실패: 로컬 변경 유지, 사용자에게 재인증 요청
- 원격 충돌: semantic merge 시도 후 충돌함 표시
- 민감정보 검출: commit/push 중단
- 네트워크 단절: 로컬 queue에 저장
- schema 실패: 정본 수정 거부, 진단 제공

어떤 실패에서도 사용자 Draft를 SQLite에만 남겨서는 안 된다. 로컬 Git working copy 또는 복구 journal에 기록한다.

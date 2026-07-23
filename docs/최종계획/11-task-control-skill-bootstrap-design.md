# Task 제어·스킬 오케스트레이션·설치 설계 doc (2026-07-23)

<!-- 최종 계획 문서 -->

## 1. 요구 & 성공기준

### Brownfield 3자 대조

| 최초 요구 | 현재 문서 기준선 | 이번 교정 요구와 변경 |
|---|---|---|
| macOS·Windows·Linux Flutter GUI | 조회, 편집, Meta 승인과 실행 버튼 중심 | Task 생성·관리뿐 아니라 시작, 일시중지, 재개, 중단, 완료와 자동 생성·처리 정책까지 GUI에서 제어한다. |
| 실행용 Meta Prompt | `under-claw-meta-prompt` adapter만 명시 | `under-claw-meta-prompt` → `under-claw-jarvis-plan-loop` → loop 내부 `under-claw-jarvis-plan`의 필수 파이프라인으로 고정한다. |
| 설치파일만으로 쉬운 설치 | OS 설치파일과 headless 바이너리만 정의 | 데스크톱 installer와 headless bootstrap 모두 setup/uninstall manifest를 공유하고 감지된 Agent host에 스킬 bundle과 adapter를 설치한다. |
| 사용자명 없는 패스워드 로그인 | 빌드 시 verifier를 번들에 포함 | 최초 repository bootstrap에서 패스워드를 정하고 repository-scoped verifier를 Git 외부 보안 설정에 저장한다. 이후 클라이언트는 target repository 연결 후 같은 verifier로 로그인한다. |

총평: 기존 데이터 정본과 Core/GUI 분리 원칙은 유지하고, 원격 Task 제어 계약·스킬 실행 계약·설치 수명주기·repository 단위 인증 경계를 보강한다.

### 성공기준

1. GUI에서 Task CRUD, 자동 생성 정책, 시작·일시중지·재개·중단·완료 요청과 실제 처리 상태를 구분해 관리한다.  
   `[verify: GUI 명세와 ControlRequest/Event 상태표를 대조한다.]`
2. 모든 Task 실행이 세 스킬을 명시적으로 거치며 특정 Agent 이름이나 모델 ID에 종속되지 않는다.  
   `[verify: skill pipeline과 provider adapter 계약을 fixture로 검증한다.]`
3. clean macOS, Windows, Linux 또는 headless 환경에서 개발도구 없이 설치·초기화·제거할 수 있다.  
   `[verify: 깨끗한 VM에서 install/setup/uninstall smoke test를 실행한다.]`
4. 최초 setup에서 target Git repository와 새 패스워드를 지정하고, 다른 기기의 Flutter 앱이 같은 repository에 연결해 패스워드로 잠금을 해제한다.  
   `[verify: 두 운영체제에서 같은 repository auth policy/version으로 성공·실패 로그인을 시험한다.]`
5. 평문 패스워드, repository verifier, GitHub token이 Git·설치파일·로그에 들어가지 않는다.  
   `[verify: secret fixture 기반 artifact/repository/log leakage test를 실행한다.]`

## 2. 채택 접근법 & 근거

채택안은 `Flutter control plane + Worklog Core + provider-neutral skill runtime + repository-scoped external verifier + manifest-driven installer`다.

- GUI는 Task 파일을 직접 고치지 않고 Core에 ControlRequest를 제출한다. 실행 Agent가 ACK하기 전에는 “요청됨”으로 표시해 원격 상태를 거짓으로 확정하지 않는다.
- `under-claw-meta-prompt`는 Draft를 실행용 Meta Prompt로 바꾸고, `under-claw-jarvis-plan-loop`가 Task 실행 전체를 감싸며, loop가 매 회차 `under-claw-jarvis-plan`을 호출한다. 세 스킬의 책임과 명시적 활성화 게이트를 모두 보존한다.
- Agent/model 차이는 runner adapter가 흡수한다. Task와 정본에는 provider model ID를 실행 의미로 박지 않는다.
- repository에는 auth policy ID·KDF 정책·version과 provider 선정 상태만 저장한다. 실제 provider는 구현 전 spike와 acceptance gate를 통과한 뒤 정하며, 후보는 검토된 PAKE(예: OPAQUE) 또는 acceptance를 만족하는 표준 외부 인증 protocol로 제한한다.
- installer가 작성한 모든 파일과 host adapter를 install manifest에 기록해 uninstall이 자기 변경만 정확히 제거하게 한다.

비교 후 버린 대안:

- 바이너리에 공용 verifier 포함: repository마다 다른 패스워드를 설정할 수 없고 패키지 분석·재배포 경계가 불명확하다.
- verifier를 Git에 commit: offline 추측 공격면과 저장소의 인증정보 commit 금지 규칙에 어긋난다.
- Agent별 별도 구현: Codex, Claude, Hermes 등에서 동작이 갈라지고 제거·업데이트가 불가능해진다.
- GUI가 Task status를 직접 덮어쓰기: 실행 Agent의 실제 상태와 GUI 표시가 불일치하고 중단 중 데이터 손상이 생길 수 있다.

## 3. 변경 범위 & 파일

변경 대상:

- `docs/README.md`: 새 계약 문서 링크와 불변조건
- `01-product-requirements.md`: GUI 제어, 스킬, setup/uninstall 요구
- `02-architecture.md`: control plane, skill runtime, repository auth 설정
- `03-data-model.md`: ControlRequest, skill pipeline, auth policy locator
- `04-task-workflow.md`: 명령/ACK 상태 전이와 필수 스킬 실행
- `05-desktop-gui.md`: Task control center와 setup/repository 연결 UX
- `06-security-auth.md`: 최초 password setup과 repository-scoped verifier
- `07-distribution.md`: manifest 기반 설치·업데이트·완전 제거
- `08-implementation-roadmap.md`: Core/GUI/installer 작업과 검증
- `09-skill-orchestration.md`: 세 스킬 및 provider adapter 상세 계약
- `10-installation-and-removal.md`: desktop/headless 설치·초기화·제거 runbook

변경하지 않는 영역:

- 기존 `ai/prompt-task/` 원문
- 기존 `.agents/`, `.claude/` 스킬 파일
- 실제 앱·Core 구현
- 실제 비밀번호, verifier, token 또는 credential 파일

## 4. 프로젝트 간 계약 영향

GUI ↔ Core:

```text
TaskCommand {
  task_id,
  operation_id,
  command: start | pause | resume | cancel | complete,
  run_id?,
  target_environment_id,
  target_agent_id?,
  expected_revision,
  reason?,
  requested_by,
  idempotency_key
}

ControlRequest는 immutable이며 ACK/reject/withdraw는 request별 고정 경로의 별도 immutable ControlDisposition Event를 remote compare-and-create한다. `start`는 operation별 Claim의 `reserved_run_id`와 Run의 `operation_id` unique constraint로 부분 실패 재진입과 duplicate Run 방지를 보장한다.
```

Core ↔ Agent runner:

```text
invoke_skill(skill_id, input_ref, run_id) -> InvocationHandle
control_run(run_id, command) -> Ack
stream_events(run_id, cursor) -> Event[]
```

필수 skill pipeline:

```text
draft
→ explicit under-claw-meta-prompt invocation
→ approved meta
→ explicit under-claw-jarvis-plan-loop invocation
→ loop round마다 explicit under-claw-jarvis-plan invocation
→ reviewer gate
→ completed 또는 blocked/failed
```

Repository auth:

```text
workdb/config/repository-auth.yaml
  auth_policy_id
  policy_version
  provider_selection_status
  verifier_provider
  verifier_locator
  kdf_policy
```

파일에는 선정 상태, locator와 공개 정책만 있고 실제 verifier 값은 없다. provider 선정과 표준 인증 protocol 계약은 `06-security-auth.md`가 normative source다.

## 5. 리스크 & 미해결 가정

- AuthProvider는 아직 미선정이며 구현 spike에서 API, 권한, 기밀성, cross-device와 실패 복구 acceptance를 확인해야 한다.  
  완화: 검토된 PAKE 또는 표준 외부 인증 protocol만 후보로 허용하고 자체 암호 protocol과 verifier를 클라이언트에 반환하거나 Git에 저장하는 후보를 제외한다.
- Private repository 선택 전에는 auth policy를 읽을 수 없다.  
  완화: 최초 기기와 새 기기 모두 GitHub 인증 → repository 선택 → password 입력 순서로 고정하고, 이후 같은 기기에서는 OS secure store cache로 잠금 화면부터 시작한다.
- 일시중지는 Agent가 안전 checkpoint를 지원해야 한다.  
  완화: 즉시 상태 변경이 아니라 `pause_requested` 후 ACK 시 `paused`; 미지원 runner는 명시적으로 거부한다.
- 사용자 수가 늘면 공유 패스워드만으로 사용자별 감사가 불가능하다.  
  완화: 첫 버전은 단일 소유자 용도로 제한하고 Event actor는 Environment/Agent identity를 함께 기록한다.
- 세 스킬의 배포 원본·라이선스·version pin 방식은 실제 bundle 조립 전 확인이 필요하다.  
  완화: release manifest에 source revision과 checksum을 필수로 기록한다.

## 6. 검증 방법

| 성공기준 | 검증 |
|---|---|
| GUI 전체 제어 | 각 command의 요청·ACK·거부·timeout fixture와 화면 상태표 확인 |
| 세 스킬 필수 사용 | Run별 invocation 순서와 skill version이 Event에 모두 기록되는지 검사 |
| 공급자 중립성 | generic mock runner, Codex adapter, Hermes adapter가 같은 contract test 통과 |
| 쉬운 설치·제거 | clean VM에서 단일 artifact 설치, setup, 앱/CLI 실행, uninstall, 잔여 파일 검사 |
| repository password | 첫 기기 setup 후 두 번째 OS에서 같은 repo 성공/오입력 실패/정책 version 갱신 확인 |
| 비밀값 비저장 | repository, build artifact strings, logs, crash dump에 secret fixture가 없는지 검사 |
| 문서 품질 | Markdown fence 균형, 상대 링크 존재, 금지 민감정보 패턴 검사 |

## 7. task 분할

1. 정본 schema에 immutable ControlRequest/ControlDisposition, Operation, SkillInvocation, repository auth policy를 추가한다.  
   검증: valid/invalid fixture와 상태 전이 테스트.  
   경계: `workdb/schemas/`, `core/` data contract.
2. provider-neutral skill runtime과 세 스킬 pipeline을 구현한다.  
   검증: mock runner로 필수 순서·실패·재시도·취소 contract test.  
   경계: Core orchestration과 adapters.
3. Flutter Task control center를 구현한다.  
   검증: widget/integration test에서 생성·시작·pause·resume·cancel·complete 요청과 ACK 표시.  
   경계: `apps/worklog_studio/`.
4. repository bootstrap과 password verifier provider를 구현한다.  
   검증: 두 OS repository 연결, 잘못된 password 거부, secret leakage test.  
   경계: Core auth와 secure store adapter.
5. manifest 기반 installer/uninstaller와 host skill adapters를 구현한다.  
   검증: clean VM 설치/재설치/업데이트/앱만 제거/완전 제거 smoke test.  
   경계: packaging 및 release automation.
6. 전체 cross-platform E2E를 수행한다.  
   검증: Mac에서 Task 생성 → Windows에서 시작 → Linux Agent 실행 → Mac에서 pause/resume/complete 확인.

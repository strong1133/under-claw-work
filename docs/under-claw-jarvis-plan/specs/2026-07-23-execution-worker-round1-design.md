# 실행 Worker 및 감사 증거 설계 doc (2026-07-23)

## 1. 요구 & 성공기준

- 승인된 최신 Meta Prompt의 start 요청을 worker가 정본에 기록된 뒤에만 실행한다.
  [verify: 프로세스 시작 시점에 Run/ControlRequest 존재를 검사하는 contract test]
- worker는 request ACK, claim, heartbeat, 실행, 완료/실패, claim 해제를 일관되게 처리한다.
  [verify: 성공·실패·취소·stale recovery 테스트]
- pipeline 검수는 runner의 자기보고 boolean이 아니라 Core가 관찰한 프로세스 증거를 요구한다.
  [verify: 증거 없는 결과 거부, exit/output hash 기반 증거 통과 테스트]
- canonical entity write는 모든 EntityKind에서 runtime contract validator를 통과한다.
  [verify: invalid entity create/update 차단 테스트]
- CLI와 Flutter 시작 동작이 worker 경로를 호출한다.
  [verify: CLI contract test와 widget/core smoke]

## 2. 채택 접근법 & 근거

`ControlRequest`와 예약 `Run`을 durable queue로 재사용하고
`TaskExecutionWorker`를 단일 실행 조정자로 추가한다. adapter는 명령 실행과 관찰 증거를
반환하고 pipeline은 trace 구조 및 reviewer artifact를 검증한다.

대안 1인 별도 daemon/메시지 큐는 배포와 복구 표면이 과도해 버렸다. 대안 2인 GUI 내부
직접 process 실행은 headless 환경과 crash recovery 계약을 깨므로 버렸다.

## 3. 변경 범위 & 파일

- `lib/core/models.dart`, `process_runner_adapter.dart`, `skill_pipeline.dart`:
  프로세스 관찰 증거와 pipeline 검증.
- `lib/core/execution_worker.dart`, `control_service.dart`, `claim_service.dart`:
  실행 상태기계, heartbeat, cancellation/recovery.
- `lib/core/canonical_repository.dart`, `schema_validator.dart`:
  canonical write-boundary 검증.
- `bin/worklog.dart`, `lib/main.dart`: worker 기반 시작/상태.
- 관련 tests: fake contract와 수명주기 검증.

기존 인증·Git sync·installer·migration 구현은 건드리지 않는다.

## 4. 프로젝트 간 계약 영향

CLI/Flutter 모두 같은 Core worker API를 사용한다. Runner JSON에 reviewer artifact가
필수이며 Core가 추가한 `process_evidence`는 exit code, output digest, adapter ID와
관찰 시각을 가진다. 특정 provider/model ID는 Task에 저장하지 않는다.

## 5. 리스크 & 미해결 가정

- Agent CLI별 비대화형 인자 계약은 설치 버전마다 다르므로 안전하게 탐지된 명령만
  실행하고, 이 회차에서는 generic process adapter를 기준 계약으로 삼는다.
- Git remote compare-and-create는 별도 Git sync 경계이며 local filesystem claim만으로
  다중 PC 배타성을 주장하지 않는다.
- OS 강제 종료 시 child process tree 정리는 플랫폼별 추가 검증이 필요하다.

## 6. 검증 방법

format, analyze, 전체 Flutter test, CLI native build, macOS build, secret scan,
`git diff --check`와 신규 worker contract test를 실행한다.

## 7. task 분할

1. 실행 증거 계약 추가 → unit test.
2. worker 상태기계/heartbeat/cancel/recovery 추가 → lifecycle test.
3. CLI/Flutter worker 연결 → command/widget smoke.
4. canonical write validator 연결 → entity-kind contract fixture.
5. 전체 검증 및 잔여 gap 보고.

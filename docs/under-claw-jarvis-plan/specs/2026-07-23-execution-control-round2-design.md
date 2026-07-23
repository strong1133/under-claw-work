# 실행 제어 Round 2 설계 doc (2026-07-23)

## 1. 요구 & 성공기준

- start는 claim 획득 뒤에만 accepted/running이 된다. claim 경쟁에서 진 요청은 pending으로 남고 재처리 가능하다. [verify: 동시 worker 회귀 테스트]
- 제어 요청의 accepted 기록 자체는 Task/Run을 바꾸지 않는다. 대상 worker가 명령을 적용한 뒤 ACK를 기록한다. [verify: control 상태 격리 테스트]
- 완료는 검증된 orchestration event와 reviewer artifact가 존재한 뒤에만 기록한다. [verify: 누락/변조 artifact 거부 테스트]
- GUI가 만든 요청은 동일 worker API에서 소비할 수 있다. [verify: request → worker integration test]

## 2. 채택 접근법 & 근거

불변 ControlRequest/Disposition과 가변 Run/Task 상태를 분리하고 worker를 유일한 실행 상태 전이자로 둔다. 분산 트랜잭션을 흉내 내는 큰 추상화보다 claim을 선행시키고 각 쓰기를 재진입 가능하게 만드는 최소 접근이다. ControlService가 ACK와 상태 전이를 동시에 하던 기존 방식은 race 복구가 불가능해 폐기한다.

## 3. 변경 범위 & 파일

- `lib/core/execution_worker.dart`: claim 선행, worker control executor, 복구
- `lib/core/control_service.dart`: immutable request/disposition 기록만 담당
- `lib/core/process_runner_adapter.dart`, `lib/core/models.dart`, `lib/core/skill_pipeline.dart`: 실제 reviewer artifact 검증
- `test/execution_worker_test.dart`: race/control/artifact 회귀

인증, 전체 GUI CRUD, 배포 서명 영역은 이번 회차에서 변경하지 않는다.

## 4. 프로젝트 간 계약 영향

CLI와 Flutter가 생성하는 ControlRequest 형식은 유지한다. `accepted`의 의미는 “worker가 명령 적용을 책임지고 수락함”으로 좁아지며, 사용자/UI가 직접 accepted를 기록해도 상태는 바뀌지 않는다. 프로세스 runner JSON은 reviewer 점수를 직접 신뢰하지 않고 `reviewer_artifact_path`를 요구한다.

## 5. 리스크 & 미해결 가정

- 파일 기반 로컬 claim은 단일 checkout 경계다. 다중 clone은 별도 Git ref CAS가 필요하다.
- pause는 runner pause capability가 있을 때만 ACK하며, 미지원 adapter에서는 거절해야 한다.
- 프로세스 crash 사이의 여러 파일 쓰기는 원자 트랜잭션이 아니므로 재진입 검증이 필수다.

## 6. 검증 방법

`flutter test test/execution_worker_test.dart`, 전체 `flutter test`, `flutter analyze`, format, CLI/macOS build, secret scan과 diff check를 수행한다.

## 7. task 분할

1. ControlService의 상태 mutation 제거 및 회귀 테스트.
2. start claim-before-ACK, 중복/경쟁/recovery 구현.
3. pause/resume/cancel worker executor와 ACK lifecycle 구현.
4. reviewer artifact 존재·내용·해시·session identity 검증.
5. 전체 검증 후 별도 검수 세션에 전달.

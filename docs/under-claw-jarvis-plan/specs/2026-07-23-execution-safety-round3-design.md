# Execution safety round 3 design (2026-07-23)

## 1. 요구 & 성공기준

원격·로컬 claim 이후의 시작 전이를 복구 가능하게 만들고, multi-environment
Task는 원격 lease 없이는 실행하지 않는다. 제어 명령은 adapter 동작 성공 뒤에만
ACK하며, reviewer artifact는 workspace와 독립 reviewer 경계를 모두 증명해야 한다.

- 각 start stage fault가 Task/Run/lease를 원상 복구하고 recovery Event를 남긴다.
  [verify: stage fault-injection parameterized test]
- 두 clone 중 하나만 lease를 획득하며 만료 후 takeover, renew, release가 CAS다.
  [verify: local bare Git two-clone test]
- multi-environment Task는 remote provider 부재/실패 시 runner를 호출하지 않는다.
  [verify: worker fail-closed test]
- pause/resume/cancel 실패는 rejected이고 상태가 바뀌지 않는다.
  [verify: async control failure test]
- symlink artifact 및 같은 producer/reviewer session은 거부한다.
  [verify: process adapter security tests]

## 2. 채택 접근법 & 근거

분산 트랜잭션을 주장하지 않고 ACK를 start의 commit point로 둔다. ACK 전 가변
Run/Task는 이전 값으로 보상하고, 획득한 lease를 release하며 immutable recovery
Event를 append한다. 원격 lease는 전용 Git ref의 commit metadata에 expiry를
기록하고 observed OID 기반 force-with-lease로 renew/takeover/release한다.

대안인 여러 정본 파일을 한 Git commit으로 직접 묶는 방식은 현재 repository API
전체를 교체하고 GUI의 uncommitted edit와 충돌하므로 버렸다.

## 3. 변경 범위 & 파일

- `models.dart`, `task_codec.dart`: explicit execution scope
- `git_remote_claim_service.dart`: provider 계약과 TTL CAS
- `execution_worker.dart`: remote-first, compensation, serialized controls
- `process_runner_adapter.dart`: safe artifact read와 session separation
- 관련 worker/remote/process adapter test

인증, 전체 GUI IA, 배포 서명은 이번 안전 경계 변경에 섞지 않는다.

## 4. 프로젝트 간 계약 영향

Task YAML에 `execution_scope: single_machine|multi_environment`를 추가한다.
기존 문서는 안전하게 `multi_environment`로 해석한다. worker 생성자는
`RemoteClaimProvider?`를 받으며 multi-environment에서 null이면 fail-closed한다.

## 5. 리스크 & 미해결 가정

Git ref CAS는 Git transport가 force-with-lease를 지원해야 한다. 지원하지 않으면
acquire/renew가 실패하고 worker는 실행하지 않는다. 파일 read의 OS-level TOCTOU를
완전히 제거하는 fd/no-follow API가 Dart 표준에 없으므로 모든 경로 구성요소의
symlink 거부, realpath containment, read 전후 stat 일치로 fail-closed한다.

## 6. 검증 방법

대상 테스트 후 전체 Flutter test, format, analyze, CLI/macOS build, smoke,
secret scan, `git diff --check`를 실행한다.

## 7. task 분할

1. Task scope와 remote lease CAS/TTL 계약 구현.
2. worker start compensation 및 fault injection 구현.
3. serialized async control processing 구현.
4. artifact containment/session 분리 강화.
5. 결정적 회귀 테스트와 전체 검증.

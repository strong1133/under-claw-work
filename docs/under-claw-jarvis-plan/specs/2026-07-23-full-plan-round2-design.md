# Full plan round 2 design (2026-07-23)

## 1. 요구 & 성공기준

최종계획 전체가 목표지만 회차 1 결과와 critic을 대조하면 Domain 계층 CRUD는 이미
동작하고, 인증·원격 제어·실행 증거·배포가 핵심 누락이다. 이번 회차는 가짜 외부
서비스나 자체 암호 프로토콜을 만들지 않고 다음 deterministic vertical slice를 닫는다.

1. 한 ControlRequest에는 accepted/rejected/withdrawn/expired/superseded 중 하나의
   immutable disposition만 생성된다.
   `[verify: 경쟁 및 중복 disposition 단위 테스트]`
2. accepted만 Task/Run 상태를 전이하고, start가 거부·철회·만료되면 예약 Run은
   `aborted_before_start`가 된다.
   `[verify: command별 lifecycle 단위 테스트]`
3. 인증 Core는 선정된 외부 provider 없이는 fail closed하고, password를 저장하거나
   반환하지 않으며 online rate limit과 repository/policy/environment session binding을
   강제한다.
   `[verify: fake accepted provider를 경계 밖에 둔 contract test]`
4. GUI/CLI에서 disposition 생성과 pending/최종 상태를 확인할 수 있다.
   `[verify: widget test 및 CLI smoke]`

Brownfield 3자 대조:

| 최초 요구 | 현재 구현 | 회차 2 교정 |
|---|---|---|
| immutable control + ACK 경합 | 임의 ID event, process-local 사전 조회 | request별 고정 파일 exclusive-create |
| reject/withdraw/timeout | accepted만 상태 반영 | 전 disposition 및 start cleanup |
| repository password | `UnsupportedError` stub | fail-closed provider contract, rate limit/session |
| GUI 제어 상태 | 요청 버튼과 문자열 메시지 | pending/최종 disposition projection |

## 2. 채택 접근법 & 근거

정본 파일 시스템의 `create(exclusive: true)`를 로컬 compare-and-create primitive로
재사용한다. disposition ID를 request ID에서 결정적으로 유도하면 별도 lock 없이 한
경로만 승리한다. 원격 Git CAS는 별도 회차가 필요하며 이번 구현을 원격 성공으로
표현하지 않는다.

인증은 `RepositoryAuthProvider` 포트와 `RepositoryAuthGate` application service로
나눈다. provider는 password를 입력 인자로만 받고 opaque short-lived grant만
반환한다. 자체 KDF/verifier 저장은 구현하지 않는다.

버린 대안은 Git에 password verifier를 저장하는 방식이다. offline guessing 방지와
비밀정보 commit 금지를 동시에 위반한다.

## 3. 변경 범위 & 파일

- `lib/core/control_service.dart`: disposition CAS와 lifecycle
- `lib/core/auth.dart`: provider contract, throttling, bound session
- `lib/main.dart`: control 상태 표시
- `bin/worklog.dart`: disposition 종류 확장
- `test/`: contract, lifecycle, widget 검증

회차 1의 CRUD 파일과 사용자 데이터는 유지한다. 외부 push/release/signing은 하지 않는다.

## 4. 프로젝트 간 계약 영향

`addDisposition`은 생성된 canonical entity를 반환한다. 동일 request의 두 번째 결과는
`DISPOSITION_EXISTS`로 실패한다. 인증 provider는 repository ID, policy version,
environment ID에 묶인 `AuthGrant`만 반환하며 password/verifier 필드는 계약에 없다.

## 5. 리스크 & 미해결 가정

- Git clone 간 진짜 remote CAS는 아직 없다. 후속 remote-ref/API adapter가 필요하다.
- accepted AuthProvider 서비스가 아직 선정되지 않았다. Core는 그 전까지 fail closed다.
- OS secure store와 cross-device provider E2E는 외부 서비스·플랫폼 runner가 필요하다.
- 회차 1의 큰 `main.dart` 분리는 이번 외과적 변경 범위 밖이다.

## 6. 검증 방법

- `dart format --output=none --set-exit-if-changed .`
- `flutter analyze`
- `flutter test`
- `flutter build macos`
- CLI build/smoke와 `tool/secret_scan.sh`
- `git diff --check`

## 7. task 분할

1. Control disposition CAS/lifecycle를 구현하고 단위 테스트한다.
2. Auth provider contract/rate-limit/session binding을 구현하고 단위 테스트한다.
3. GUI/CLI에 control 상태를 투영하고 widget/smoke test한다.
4. 전체 deterministic 검증을 실행하고 미완료 외부 gate를 정직하게 기록한다.

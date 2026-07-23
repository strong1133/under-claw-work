# ROUND 2 Core 정본·setup 설계 doc (2026-07-23)

## 1. 요구 & 성공기준

현재 Task-only vertical slice를 교정해 Domain, Milestone, Objective,
Knowledge, Reference, Event, Claim, Run, Invocation과 Control 정본을 공용
Core가 다룬다. 사용자는 고정 sample workspace 대신 local Git path 또는
Private remote를 setup에 지정한다.

- 정본 CRUD 뒤 SQLite를 삭제해도 모든 entity가 복구된다.
  `[verify: full rebuild test]`
- 잘못된 ID prefix와 끊어진 핵심 관계는 commit 전에 거부된다.
  `[verify: repository validator test]`
- setup은 기존 local Git repository를 연결하거나 새 local repository를
  초기화하며 remote clone을 지원한다. 비밀은 인자나 설정에 저장하지 않는다.
  `[verify: setup sandbox tests]`
- ControlRequest는 SQLite보다 immutable 정본 파일을 먼저 compare-and-create한다.
  `[verify: DB 삭제 후 control rebuild 및 duplicate test]`

### Brownfield 3자 대조

| 최초 요구 | 현재 구현 | ROUND 2 교정 |
|---|---|---|
| 전체 정본 graph | Task만 YAML decode | 공용 canonical entity와 relation validator |
| SQLite 전체 복구 | Task만 rebuild | 전체 entity/control/run/invocation projection |
| 사용자 repository setup | GUI 고정 sample 경로 | CLI/GUI 공용 `SetupService` |
| immutable control 원자성 | DB-first 후 파일 작성 | file-first compare-and-create 후 rebuild |

## 2. 채택 접근법 & 근거

YAML을 임의 map으로 보존하는 작은 `CanonicalEntity` repository를 채택한다.
계획의 schema가 계속 확장되므로 모든 entity마다 조기 강타입 계층을 만드는
대안보다 정본 필드 손실 없이 외과적으로 CRUD와 관계 검증을 제공한다.

버린 대안은 SQLite-first transaction이다. SQLite는 삭제 가능한 projection이므로
정본 생성 성공보다 먼저 상태를 확정할 수 없다.

## 3. 변경 범위 & 파일

- `lib/core/canonical_repository.dart`: entity CRUD, prefix/relation validator
- `lib/core/setup_service.dart`: local init/connect와 remote clone
- `lib/core/workspace.dart`: 정본 directory registry
- `lib/core/projection.dart`: 전체 정본 projection rebuild
- `lib/core/control_service.dart`: canonical-first request/disposition
- `bin/worklog.dart`, `lib/main.dart`: 공용 setup 진입
- `test/round2_core_test.dart`: sandbox 계약 검증

인증 provider 선정, 자체 암호, destructive credential 처리와 release signing은
변경하지 않는다.

## 4. 프로젝트 간 계약 영향

CLI와 Flutter는 `SetupService.setup(SetupRequest)`를 공유한다. Core는 정본
상대경로와 entity ID를 public contract로 제공하고 SQLite row를 API로 노출하지
않는다.

## 5. 리스크 & 미해결 가정

- 원격 Private clone credential은 OS/Git credential helper가 제공해야 한다.
  Core는 token-bearing URL을 거부한다.
- 모든 계획 schema의 세부 필드 validation은 후속 JSON Schema 작업이 필요하다.
- 실제 원격 compare-and-create는 GitHub API adapter가 필요하다. 이번 변경은
  local immutable compare-and-create와 projection recovery까지만 보장한다.

## 6. 검증 방법

`dart format`, `flutter analyze`, 전체 `flutter test`, macOS build,
CLI setup sandbox, SQLite 삭제 rebuild, secret scan을 실행한다.

## 7. task 분할

1. Workspace와 canonical repository/validator 구현.
2. 전체 projection rebuild와 canonical-first Control 구현.
3. SetupService와 CLI/GUI setup 진입 구현.
4. sandbox/E2E tests 및 문서 정렬.

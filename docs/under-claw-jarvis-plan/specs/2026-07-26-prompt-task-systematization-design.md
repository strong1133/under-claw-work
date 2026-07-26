# prompt-task 체계화 설계 doc (2026-07-26)

`underjoy-work-log`의 raw prompt-task 운영을 under-claw-work의 정본 Task 모델로
옮기고, 메타 프롬프팅 작성까지 실무에서 쓸 수 있게 만드는 작업의 설계다.
AI 기반 자동 실행은 이번 범위에서 제외한다.

## 1. 요구 & 성공기준

요구 1~10은 사용자 입력을 그대로 따른다. brownfield 3자 대조 결과 요구 2·4·5·6·7의
데이터 구조는 이미 구현되어 있고, 실제 격차는 아래 6개다.

| ID | 성공기준 | verify |
|---|---|---|
| S1 | `요청완료` 블록이 완료가 아니라 대기 상태로 들어온다 | 마이그레이션 테스트: 상태 분포에 `completed`가 없고 `metaRequested`/`metaReview`만 있음 |
| S2 | 도메인이 소스 경로별로 분리된다 | 테스트: 서로 다른 디렉터리의 블록이 서로 다른 `domain_id`를 가짐 |
| S3 | `related::` PT-id가 `related_task_ids`로 해석된다 | 테스트: 같은 import 안의 PT 참조가 TSK id로 치환됨 |
| S4 | `targets::`가 명시 매핑으로만 `project_ids`에 실리고, 매핑 없는 값은 구조화 필드에 들어가지 않는다 | 테스트: 로컬 절대경로 target이 `project_ids`에 나타나지 않고 리포트의 `residue`에만 남음 |
| S5 | 문서 파일(`_SYSTEM.md` 등)이 Task로 import되지 않는다 | 테스트: `skipped`에 포함, `blocks`에서 제외 |
| S6 | MacBook 호스트에서 CLI만으로 `대기 목록 → 메타 작성 → 회수 → 승인` 루프가 돈다 | 실제 워크스페이스에서 명령 시퀀스 실행 |
| S7 | GUI에서 ULID를 타이핑하지 않고 Domain/Milestone을 선택할 수 있다 | 위젯 테스트 |
| S8 | 파일을 Reference 정본 데이터로 편입하고 Task 컨텍스트에서 되읽을 수 있다 | 왕복 테스트 |
| S9 | 기존 게이트 전부 통과 | `dart format` / `flutter analyze` / `flutter test --exclude-tags=golden` / `tool/secret_scan.sh` |

## 2. 채택 접근법 & 근거

### 비교한 대안

**A. 데이터 모델 재설계** — Task 스키마를 raw 포맷에 맞춰 다시 짠다.
버린 이유: 3자 대조 결과 요구 2·4·5·6·7이 이미 v3 스키마로 충족된다. 재설계는
과구현이고 기존 51개 테스트 파일의 계약을 깬다.

**B. 마이그레이션 매핑만 교정** — 파서·매핑 결함 5건만 고친다.
버린 이유: 요구 3·8·9의 실무 격차(메타 루프, 파일 데이터화, GUI ULID 수기입력)가
남아 "실무에서 쓸 수 있을 정도"에 도달하지 못한다.

**C. (채택) 외과적 격차 정리** — 데이터 모델은 유지하고, 실측으로 확인된 격차
6건만 좁힌다.
채택 이유: 3자 대조의 "이미 부합" 패스트패스를 적용하면 변경 표면이 가장 작고,
성공기준 S1~S9가 전부 결정적으로 검증 가능하다.

### 설계 결정 3건

**D1. targets는 명시 매핑으로만 정본에 들어간다.**
코퍼스의 `targets::` 값 41건 중 다수가 `~/work/<제품저장소>/...` 같은
**로컬 절대경로**다. 이를 자동으로 Project 엔티티화하면
`docs/domain-runtime-configuration.md`의 "canonical 엔티티에 로컬 경로를 저장하지
않는다" 불변식을 정면으로 위반한다. 따라서 호출자가 `target 문자열 → PRJ- id`
매핑을 명시 제공할 때만 연결하고, 매핑되지 않은 값은 구조화 필드에 넣지 않고
마이그레이션 리포트의 `residue`로만 남긴다. 로컬 경로를 Repository 엔티티에 바인딩하는
것은 요구 10이 정의한 **사용자 자발 영역**이다.

**D2. `요청완료`는 완료가 아니라 대기다.**
`ai/prompt-task/_SYSTEM.md`가 "상태는 사용자가 직접 기입하고 작업 수행도 사용자
소관"이라고 규정하므로 `요청완료`는 "요청 작성을 끝냈다"는 뜻이다. Meta가 없으면
`metaRequested`(메타 작성 대기), 있으면 `metaReview`(검토 대기)로 매핑한다.
`완료`/`done` 단독 라벨만 `completed`로 남긴다.

**D3. 메타 생성은 어댑터가 아니라 스킬+CLI 루프다.**
요구 10이 under-claw-work를 "스킬 모음이자 업무지침"으로 정의한다. MacBook
호스트용 프로세스 어댑터를 새로 만들지 않고, `worklog task-pending-meta`로 대기
목록을 노출하면 호스트 Agent가 `$under-claw-meta-prompt`를 실행하고
`worklog task-prompt <id> meta <file>`로 결과를 회수한다. Hermes 어댑터는 원격
자동화용으로 그대로 둔다.

## 3. 변경 범위 & 파일

**건드리는 파일**

| 파일 | 변경 |
|---|---|
| `lib/core/legacy_migration.dart` | 문서 파일 제외, 상태 어휘, 도메인 맵, targets 명시 매핑, related 2-pass |
| `lib/core/reference_attachment.dart` (신규) | 파일을 Reference 정본 데이터로 편입 |
| `bin/worklog.dart` | `task-pending-meta`, `reference-attach` 추가, `migrate-import` 인자 확장 |
| `lib/main.dart` | 엔티티 생성 다이얼로그의 Domain/Milestone/Task 선택기 |
| `skills/under-claw-work/SKILL.md` | 메타 루프와 요구 10 경계 명문화 |
| `test/` | 위 각 항목의 회귀 테스트 |

**건드리지 않는 영역 (제약)**

- `AutoMetaWorker`, `ExecutionWorker`, `GitRemoteClaimService`, `CanonicalSyncService`
  — AI 자동 실행 경로는 이번 범위 밖이다.
- Task v3 스키마의 기존 필드 의미 — 재설계하지 않는다.
- `under-claw-jarvis-*` 3개 상위 스킬의 명시 호출 계약.
- `underjoy-work-log` 저장소 — 읽기만 한다. 51건 실제 이관은 사용자가 자기 기억DB
  레포를 지정해 수행할 영역이다(요구 10).

## 4. 프로젝트 간 계약 영향

- `LegacyMigrationService.import()` 시그니처가 바뀐다: 단일 `domainId` →
  `domainIdsBySourcePrefix` + `defaultDomainId`, 그리고 `targetProjectIds` 추가.
  호출자는 `bin/worklog.dart`와 테스트 2곳뿐이다.
- 신규 CLI 명령 2개(`task-pending-meta`, `reference-attach`)는 기존 명령을 바꾸지
  않는다.
- 정본 YAML 스키마 변경 없음. Reference는 기존 `locator {kind, value}` 계약 안에서
  `embedded_document` kind를 사용한다.
- MCP 서버가 노출하는 4개 read-only 툴의 계약은 그대로다.

## 5. 리스크 & 미해결 가정

| 리스크 | 완화 |
|---|---|
| R1: 상태 어휘 변경이 `round5_core_test.dart:132`의 `[완료] → completed` 기대를 깰 수 있다 | `완료` 단독 라벨은 그대로 `completed`로 남기고 `요청완료`만 재매핑 |
| R2: `import()` 시그니처 변경이 기존 테스트 2건을 깬다 | 두 테스트를 같은 커밋에서 갱신하고 의미 보존 여부를 assert |
| R3: 첨부 파일이 정본 레포를 키운다 | 텍스트만 편입하고 크기 상한을 두며, 시크릿 스캔 대상에 포함 |
| R4: solo 진행이라 독립 검수가 없다 | `DEGRADED_REVIEW` 공개 + 결정적 실행 검증으로 보완 |

**미해결 가정 (확인 필요)**

- 실제 이관 시점과 대상 워크스페이스는 사용자가 정한다. 이번 작업은 도구만
  준비한다.
- `targets::`의 로컬 경로를 어떤 Repository/Project 엔티티에 바인딩할지는 사용자
  결정 영역이다.

## 6. 검증 방법

| 성공기준 | 검증 |
|---|---|
| S1~S5 | `test/legacy_migration_mapping_test.dart` (신규) — 실코퍼스 구조를 재현한 픽스처 |
| S6 | 스크래치 워크스페이스에서 CLI 시퀀스 실제 실행 |
| S7 | `test/widget_test.dart` 확장 |
| S8 | `test/reference_attachment_test.dart` (신규) |
| S9 | `dart format --output=none --set-exit-if-changed .`, `flutter analyze`, `flutter test --exclude-tags=golden`, `bash tool/secret_scan.sh` |

## 7. task 분할

의존 순서: T1 → T2 → T3 → T4 → T5 (파일 경계가 겹치지 않아 순서는 느슨하다).
solo 진행이므로 작업 agent와 검수 agent를 분리하지 못한다 → `DEGRADED_REVIEW`.

| # | task | 파일 경계 | 검증 |
|---|---|---|---|
| T1 | 마이그레이션 매핑 교정 (문서 제외 / 상태 어휘 / 도메인 맵 / targets 명시 매핑 / related 2-pass) | `lib/core/legacy_migration.dart`, `bin/worklog.dart` | S1~S5 테스트 |
| T2 | 메타 대기 큐 CLI + 스킬 문서의 루프 명문화 | `bin/worklog.dart`, `skills/under-claw-work/SKILL.md` | S6 실행 확인 |
| T3 | GUI 엔티티 생성 다이얼로그의 ULID 수기입력 제거 | `lib/main.dart` | S7 위젯 테스트 |
| T4 | 파일 → Reference 정본 데이터 편입 | `lib/core/reference_attachment.dart`, `bin/worklog.dart` | S8 왕복 테스트 |
| T5 | 요구 10 경계 문서화 | `README.md`, `skills/under-claw-work/SKILL.md` | 문서 리뷰 |

## 8. 구현 결과 (실코퍼스 실행 검증)

`underjoy-work-log/ai/prompt-task`(240개 일자 파일)를 스크래치 워크스페이스로
import한 결과다. 원본 저장소는 읽기만 했다.

| 항목 | 변경 전 | 변경 후 |
|---|---|---|
| 파싱된 블록 | 51 (`_SYSTEM.md` 예시 포함) | **50** + skipped 2 (규약 문서) |
| 상태 | `completed` 51 | **`metaRequested` 38 · `metaReview` 12 · `completed` 0** |
| 도메인 | 1개로 붕괴 | **도메인 A 47 · 도메인 B 2 · 도메인 C 1** |
| `related` 연결 | 0 | **6개 Task** (related 보유 7블록 중 1건은 자기참조만이라 제외) |
| `targets` 처리 | 41건 무단 폐기 | `project_ids`는 명시 매핑만, 미매핑 **60건은 리포트 `residue`에 보존** |

미매핑 잔여는 단일 `residue` 배열에 `{legacy_id, field, value, reason}`으로
기록한다(설계 시점의 `unmapped_targets`/`unresolved_related` 분리 안을 통합).

사용자의 Draft 원문에 포함된 로컬 경로는 그대로 보존한다. 정본에서 배제하는 것은
구조화 필드이지 사용자가 직접 쓴 요청 본문이 아니다.

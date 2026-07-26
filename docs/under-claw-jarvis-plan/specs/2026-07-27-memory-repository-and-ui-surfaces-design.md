# 기억 저장소 규격화와 UI 표면 설계 doc (2026-07-27)

요구 1~10에 대한 재검수 결과와, 사용자가 추가로 지정한 두 설계 과제
(기억 저장소 저장 구조 명세 / Task·Prompt 관리 UI 포인트)를 닫는 작업의 설계다.
직전 라운드 문서는 `2026-07-26-prompt-task-systematization-design.md`이며 이 문서는
그 후속이다.

## 1. 요구 준수 재검수 (brownfield 3자 대조)

| 요구 | 현재 `dev` 구현 | 판정 |
|---|---|---|
| 1 raw prompt 운영 체계화 | `LegacyMigrationService`, 정본 Task 모델, 실코퍼스 검증 | 도구 충족 · 실제 이관은 사용자 영역(요구 10) |
| 2 상태값 | `TaskStatus` 11-state | 충족 |
| 3 meta 작성 요청 | CLI 7단계 루프, GUI `Request Meta`, evidence 게이트 | 충족 |
| 4 발급 즉시 고유 ID | `newId('TSK')` ULID | 충족 |
| 5 Domain·Milestone 선택적 종속 | 무소속·Domain-only·Domain+Milestone 허용, milestone-only 거부 | 충족 |
| 6 상하위·연관 | `parent_task_id`, `related_task_ids`, `relations.yaml` | 충족 |
| 7 자동처리 여부 | `processing_mode` + 파생 옵션 4종 | 데이터 구조 충족(실행은 범위 밖) |
| 8 참고 데이터 | Knowledge·Reference·Match, `reference-attach` | 충족 |
| 9 명세·설계·구현 | 구현·게이트 통과 | 문서-구현 불일치 1건 잔존(G1) |
| 10 스킬 모음 + 사용자 기억DB 경로 | README·SKILL.md 명문화 | 명문화 충족 · 트리 규격화 미충족(G2~G4) |

데이터 구조는 요구를 충족한다. 남은 격차는 6건이다.

| ID | 격차 | 근거 |
|---|---|---|
| G1 | 정본 Task 디렉터리 스펙과 구현이 다르다 | `03-data-model.md:144`·`04-task-workflow.md:33`은 `prompt.draft.md`/`prompt.meta.md`/`artifacts.md` 분리 파일을 규정하나 구현은 `task.yaml` 인라인 |
| G2 | 기억 저장소 폴더 트리가 Git에 없다 | `ensureLayout()`이 24개 디렉터리를 만들지만 빈 디렉터리는 커밋되지 않음. clone 후 `events`·`runs`·`claims`·`config`·`matches`·`invocations` 부재 |
| G3 | 기억 저장소 레이아웃 명세 문서가 없다 | README `## 저장소 구조`는 제품 소스 레포 설명. `03-data-model.md`는 엔티티별 경로만 흩어 놓음 |
| G4 | 레이아웃 검증이 없다 | `worklog doctor`가 `workspace=ok`를 무조건 출력 |
| G5 | UI 포인트가 Flutter 단독이다 | MCP 서버는 read-only 4툴뿐 |
| G6 | Windows CI가 red다 | `b7fe233` 기존 결함 2건 |

## 2. 성공기준

| ID | 성공기준 | verify |
|---|---|---|
| S14 | Windows에서 전체 테스트가 통과한다 | CI 3-OS green |
| S15 | 기억 저장소를 clone하면 규격 트리가 그대로 존재한다 | `git ls-files`에 모든 정본 디렉터리가 나타남 |
| S16 | 레이아웃 매니페스트로 트리 규격과 버전을 확인할 수 있다 | 매니페스트 왕복 테스트 |
| S17 | `worklog doctor`가 누락·손상된 레이아웃을 실제로 잡아낸다 | 정상/디렉터리 삭제/버전 불일치 테스트 |
| S18 | 정본 문서와 구현이 일치한다 | 문서 리뷰 + 경로 grep |
| S19 | Obsidian이 기억 저장소를 vault로 읽고 Task·Domain·Knowledge를 탐색할 수 있다 | export 왕복 테스트(frontmatter·wikilink·Draft 본문) |
| S20 | Flutter에서 상태·Domain·텍스트로 Task를 좁혀 찾을 수 있다 | 위젯 테스트 |
| S21 | 로컬 웹 UI가 loopback에만 바인딩하고 토큰 없는 요청을 거부한다 | 서버 테스트(바인딩 주소·인증·Origin) |
| S22 | 기존 게이트 전부 통과 | `dart format` / `flutter analyze` / `flutter test` / `tool/secret_scan.sh` |

## 3. 채택 접근법과 설계 결정

### D4. 트리 규격화는 `.gitkeep` + 레이아웃 매니페스트로 한다

빈 디렉터리는 Git에 담기지 않으므로, `ensureLayout()`이 각 정본 디렉터리에
`.gitkeep`을 함께 씨딩한다. 동시에 `workdb/workspace.yaml`을 정본 매니페스트로
커밋해 "이 저장소는 under-claw-work 레이아웃 vN을 따른다"를 데이터로 남긴다.

`.gitkeep`이 기존 읽기 경로를 오염시키지 않음을 확인했다.
`WorkspaceFileSystem.listFiles`의 호출자는 두 곳뿐이고 둘 다 정본 파일명을
필터한다 — `CanonicalRepository.list`는 `_isCanonicalFile`, `TaskRepository.list`는
`task.yaml`/`TSK-*.yaml`. 따라서 `.gitkeep`은 무해한 placeholder다.

대안으로 검토한 "매니페스트만 두고 디렉터리는 필요 시 생성"은 clone 직후
사용자가 트리를 눈으로 확인할 수 없어 "규격화" 요구를 충족하지 못해 버렸다.

### D5. Obsidian은 정본이 아니라 단방향 파생 vault다

사용자가 프롬프트 정본을 `task.yaml` 인라인으로 유지하기로 확정했으므로,
Obsidian은 정본 포맷을 바꾸지 않고 붙여야 한다. 정본에서 생성한 읽기 전용 vault를
호스트 로컬(`.worklog/obsidian/`, gitignore 대상)에 만든다.

- Domain·Milestone·Task·Knowledge·Reference를 각각 하나의 노트로 export한다.
- frontmatter에 `id`·`type`·`status` 등 속성을 넣어 Obsidian properties로 읽히게 한다.
- 관계는 `[[wikilink]]`로 연결해 그래프 뷰와 백링크가 동작하게 한다.
- Task 노트 본문에 Draft와 Meta를 섹션으로 펼쳐 실제 프롬프트를 읽게 한다.
- 모든 노트 frontmatter에 `generated: true`와 정본 경로를 남겨 파생물임을 알린다.

**편집 회수는 이번 범위 밖이다.** 상태 전이와 Meta 승인은 evidence 게이트를 거쳐야
하는데 Obsidian은 그 게이트를 강제할 수 없다. vault에서 고친 내용을 정본으로
되돌리는 경로는 만들지 않으며, 노트와 README에 그 사실을 명시한다.

### D6. 로컬 웹 UI는 loopback 전용 · 세션 토큰 · 읽기 전용으로 시작한다

사용자가 지적한 보안 우려를 설계로 좁힌다.

- `InternetAddress.loopbackIPv4`에만 바인딩한다. 외부 인터페이스 바인딩 옵션을
  제공하지 않는다.
- 기동 시 `Random.secure()`로 세션 토큰을 발급해 URL과 함께 stdout에 1회만 출력한다.
  Git·정본·로그에 저장하지 않는다.
- 모든 요청은 토큰을 검사하고, `Host` 헤더가 loopback인지 확인해 DNS rebinding을
  막는다.
- 이번 라운드는 조회 전용이다. 쓰기 엔드포인트가 없으므로 CSRF 표면이 없다.
- repository password 인증과 무관하다. 이것은 전송 계층의 1회성 세션 토큰이며
  `06-security-auth.md`가 잠가 둔 provider 선정 게이트를 건드리지 않는다.
  자체 암호 프로토콜을 발명하지 않는다.

새 의존성을 추가하지 않는다. `dart:io`의 `HttpServer`로 충분하다.

### D7. G1은 문서를 구현에 맞춰 정정한다

사용자가 인라인 유지를 선택했다. Task 1건이 파일 1건이라 원자적 쓰기와 잠금
경계가 단순하다는 현재 구현의 이점을 유지하고, `03-data-model.md`와
`04-task-workflow.md`의 분리 파일 스펙을 실제 구현대로 고친다. 근거를 문서에 남겨
다음 독자가 다시 분리 파일로 되돌리려 하지 않게 한다.

## 4. 변경 범위

**건드리는 파일**

| 파일 | 변경 |
|---|---|
| `test/host_binding_test.dart` | 권한 assertion에 Windows 가드 |
| `test/task_automation_integration_test.dart` | tearDown 전 projection dispose |
| `lib/core/workspace.dart` | `.gitkeep` 씨딩, 레이아웃 매니페스트, 레이아웃 검증 |
| `lib/core/worklog_core.dart` | 신규 export |
| `bin/worklog.dart` | `doctor` 실검증, `obsidian-export`, `serve` |
| `lib/core/obsidian_export.dart` (신규) | 파생 vault 생성 |
| `lib/core/local_web_server.dart` (신규) | loopback 조회 서버 |
| `lib/main.dart` | Task 목록 필터·검색 |
| `docs/최종계획/03-data-model.md`, `04-task-workflow.md` | G1 정정 |
| `docs/최종계획/12-memory-repository-layout.md` (신규) | 기억 저장소 레이아웃 normative spec |
| `README.md`, `README.en.md`, `skills/under-claw-work/SKILL.md` | 신규 표면 안내 |
| `test/` | 위 각 항목의 회귀 테스트 |

**건드리지 않는 영역**

- Task v3 정본 스키마의 필드 의미와 프롬프트 인라인 저장 방식.
- `AutoMetaWorker`, `ExecutionWorker`, `CanonicalSyncService` 등 AI 자동 실행 경로.
- `under-claw-jarvis-*` 3개 스킬의 명시 호출 계약.
- repository password 인증 — 여전히 `pending_selection`이다.
- 사용자의 기억 저장소 내용 — 도구는 레이아웃만 보장하고 Domain·기록을 만들지 않는다.

## 5. 리스크

| 리스크 | 완화 |
|---|---|
| R5: `.gitkeep`이 디렉터리 스캔을 오염시킨다 | 호출자 2곳이 모두 정본 파일명을 필터함을 확인. 회귀 테스트로 고정 |
| R6: 기존 워크스페이스에 매니페스트가 없어 doctor가 오탐한다 | 매니페스트 부재는 실패가 아니라 `layout=unversioned` 경고로 보고하고 `ensureLayout()`이 채운다 |
| R7: Obsidian vault를 정본으로 오해한다 | frontmatter `generated: true` + 노트 상단 경고 + `.worklog/` 하위(gitignore) 기본 출력 |
| R8: 웹 서버가 실수로 외부에 노출된다 | 바인딩 주소를 API에서 고정하고 테스트로 loopback을 assert. 외부 바인딩 옵션 미제공 |
| R9: 세션 토큰이 로그에 남는다 | stdout 1회 출력, 파일·정본 미기록, secret scan 대상 |

## 6. task 분할

의존 순서: T10 → T11 → T12 → T13 → T14 → T15 → T16 → T17.
solo 진행이므로 작업 agent와 검수 agent를 분리하지 못한다 → `DEGRADED_REVIEW`.

| # | task | 파일 경계 | verify |
|---|---|---|---|
| T10 | Windows CI 결함 2건 수정 | `test/host_binding_test.dart`, `test/task_automation_integration_test.dart` | S14 |
| T11 | 레이아웃 규격화(`.gitkeep` + 매니페스트) | `lib/core/workspace.dart`, `.gitignore` | S15·S16 |
| T12 | `worklog doctor` 실검증 | `lib/core/workspace.dart`, `bin/worklog.dart` | S17 |
| T13 | 기억 저장소 레이아웃 명세 + G1 문서 정정 | `docs/최종계획/12-*.md`(신규), `03-*.md`, `04-*.md` | S18 |
| T14 | Obsidian 파생 vault export | `lib/core/obsidian_export.dart`, `bin/worklog.dart` | S19 |
| T15 | Flutter Task 목록 필터·검색 | `lib/main.dart` | S20 |
| T16 | 로컬 loopback 조회 서버 | `lib/core/local_web_server.dart`, `bin/worklog.dart` | S21 |
| T17 | 문서·스킬 안내 정렬 | `README.md`, `README.en.md`, `skills/under-claw-work/SKILL.md` | 문서 리뷰 |

## 7. 구현 결과 (실행 검증)

컴파일한 CLI 바이너리로 스크래치 워크스페이스에서 실제 실행한 결과다.

**레이아웃 규격화 (S15·S16·S17)**

| 검증 | 결과 |
|---|---|
| 초기화 전 `doctor` | `workspace=incomplete`, 누락 디렉터리 22개를 이름으로 출력 |
| `init` 후 `doctor` | `workspace=ok`, `layout_version=1/1` |
| 커밋 후 clone | 정본 디렉터리 **22개 + 매니페스트가 그대로 재현** |
| 매니페스트 없는 저장소 | `unversioned` (실패 아님) |
| 버전 불일치 | `version_mismatch` |
| placeholder 삭제 | `not_portable`, 해당 디렉터리 이름 출력 |

**구현 중 발견한 추가 결함 1건**

`worklog init`으로 초기화한 저장소가 `.worklog/projection.sqlite3`을 커밋했다.
`SetupService`에만 있던 `.gitignore` 보장이 `init` 경로에 없었기 때문이다.
"SQLite projection은 Git에 포함하지 않는다"는 불변식을 정면으로 위반하므로,
보장을 `Workspace.ensureLayout()`으로 옮겨 모든 진입점이 동일하게 적용받게 했다.
재검증 결과 `.worklog` 추적 파일 0건이다.

**Obsidian 파생 vault (S19)**

Task 노트가 frontmatter에 `id`·`status`·`draft_revision`·`generated: true`·
`canonical_source`를 싣고, Draft를 본문 섹션으로 펼치며, Domain·Milestone·parent·
related를 `[[wikilink]]`로 연결하고 각 링크 대상 노트가 실제로 존재함을 확인했다.
기본 출력은 `.worklog/obsidian/`이라 커밋되지 않는다.

**로컬 웹 뷰 (S21)**

| 요청 | 응답 |
|---|---|
| 토큰 없음 | `401` |
| 길이가 같은 잘못된 토큰 | `401` |
| `Host: attacker.example` | `403` |
| `POST`/`PUT`/`DELETE`/`PATCH` | `405` |
| 유효 토큰 + loopback Host | `200` + Task JSON |

`lsof -nP -iTCP:<port> -sTCP:LISTEN`이 `127.0.0.1:<port>`만 보여준다. 와일드카드
바인딩이 없다. 응답에 `Access-Control-Allow-Origin`이 없고 `X-Frame-Options: DENY`,
`Cache-Control: no-store`가 붙는다.

**게이트 (S14·S22)**

`dart format --set-exit-if-changed` 통과, `flutter analyze` 이슈 0,
`flutter test --exclude-tags=golden` **343건 통과**(기존 313 + 신규 30),
`tool/secret_scan.sh` 통과. Windows 결함 2건은 수정했으나 macOS에서 재현할 수
없으므로 CI 왕복으로만 확정된다.

## 8. 합의 게이트

독립 검수 컨텍스트가 없어 solo fallback으로 진행한다. 역할 패스(요구 대조 /
데이터 계약 / 보안)를 분리해 수행하고, 결정적 실행 검증(S14~S22)으로 게이트를
대체하며 최종 보고에 `DEGRADED_REVIEW`를 공개한다.

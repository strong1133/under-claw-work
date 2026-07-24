# 통합 기억·Flutter·Notion 설계 doc (2026-07-24)

## 1. 요구 & 성공기준

추가 요구의 Core 범위는 Domain·Milestone·Task와 Environment·Agent의 불변 ID 및 수정 가능한 별칭, Knowledge·Reference의 user/agent/hybrid Match, 승인된 Match와 scope에 기반한 agent 통합 기억이다. 현재 구현과 테스트가 이미 이 계약을 충족하므로 해당 영역은 유지한다.

| 최초 계획 | 현재 구현 | 교정 요청 | 판정 |
|---|---|---|---|
| provider-neutral Environment/Agent | 불변 ENV/AGT ID, `machine_key`, 별칭 변경, 환경-에이전트 연결 | Mac/Hermes 등 환경별 고유 식별·별칭 수정 | ✅ 유지 |
| scoped Knowledge/Reference | manual/agent/hybrid Match 서비스와 승인·거절·회수 provenance | 사용자·agent·둘 다 자료 매칭 | ⚠️ 매칭 생성 경로 배선 |
| 영구 Knowledge graph | Git 정본 scope/승인 Match recall, supersede, 보안 필터 | agent 통합 기억 | ✅ 유지 |
| Flutter Desktop 관리 | Core 화면과 일부 Orca/Warp 계열 토큰 | 전 UI D2Coding 16pt, 통합 UX | ⚠️ 교정 |
| Git 정본과 선택적 외부 연동 | Notion fake contract와 reconcile E2E | Flutter·Notion 동시 관리 | ➕ 실제 transport/UI 필요 |

성공기준:

1. 모든 Flutter 텍스트가 bundled D2Coding 16pt를 사용한다. `[verify: theme/widget invariant test]`
2. 고정 navigation shell에서 Work, Context, Runtime, Notion 영역에 접근한다. `[verify: widget navigation test]`
3. 실제 Notion REST transport가 create/update/read/query를 수행하고 token을 출력·Git·SQLite에 남기지 않는다. `[verify: injected HTTP client/secure-store tests + secret scan]`
4. Notion inbound는 Core reconcile과 Git commit 성공 후에만 cursor를 acknowledge한다. `[verify: commit failure redelivery E2E]`
5. 충돌은 blind overwrite 없이 UI 상태로 노출된다. `[verify: conflict controller/widget tests]`
6. 기존 Environment/Agent/Match/Recall 및 실행 불변조건 회귀가 없다. `[verify: full flutter test]`

인증 provider 선정과 Hermes 실행 지원은 기존 acceptance gate를 유지한다. 외부 검토 없이 잠금을 해제하거나 지원 완료를 주장하지 않는다.

## 2. 채택 접근법 & 근거

채택 구조는 `Unified workspace shell → Notion sync controller → async NotionSyncAdapter → HTTP client / OS secure store`다. Git YAML·Markdown만 정본이며 Notion page와 local sync state는 projection이다.

- 기존 동기 Notion port를 단일 async port로 승격한다. 동기/비동기 이중 구현은 정책 우회 경로를 만들므로 두지 않는다.
- cursor는 API timestamp·pagination 상태를 담을 수 있는 opaque string으로 취급한다.
- HTTP client는 주입 가능하게 만들어 credential-free contract test를 수행한다.
- token은 `flutter_secure_storage`에만 저장하고 Git에는 opaque locator와 database mapping만 둔다.
- 초기 동기화는 사용자가 누르는 `Sync now`만 지원한다. background sync는 명시적 흐름과 충돌 처리가 검증된 뒤의 후속 범위다.
- Orca/Warp는 공개적으로 관찰 가능한 밀도 높은 master/detail, command/navigation, 상태 표시 패턴을 자체 token으로 구현한다. 상표·로고·독점 자산·정확한 자산 복제는 하지 않는다.

버린 대안:

- Notion을 제2 정본 또는 last-write-wins 저장소로 사용: Git 단일 정본과 immutable audit를 깨므로 제외.
- `curl` blocking bridge: UI thread, timeout, token 노출 제어가 취약해 제외.
- sync/async 이중 adapter: 두 정책 경로의 drift 위험 때문에 제외.
- 화면별 개별 Notion 버튼과 즉시 background sync: commit-before-ack와 충돌 UX가 분산되므로 제외.

## 3. 변경 범위 & 파일

1. Notion async/production: `lib/core/notion_sync_adapter.dart`, 새 HTTP client·secret/config·coordinator 파일, 관련 tests.
2. Flutter: `lib/ui/app_theme.dart`, `typography.dart`, 새 workspace shell 및 Notion setup/sync/conflict 화면, `lib/main.dart`, widget/golden tests.
3. composition/dependency: `pubspec.yaml`, `lib/core/worklog_core.dart`, platform secure-store 설정.
4. 문서: 최종계획 00/02/03/05와 본 설계 문서를 실제 구현에 맞게 갱신한다.

Environment/Agent/Match/Recall 서비스와 schema는 이미 부합하므로 기능 변경하지 않는다. 인증 provider와 Hermes 실행 gate도 변경하지 않는다. dirty worktree의 기존 사용자 변경을 보존한다.

## 4. 프로젝트 간 계약 영향

단일 Flutter 프로젝트이므로 별도 프로젝트 API 계약은 없다. 내부 port는 다음처럼 바뀐다.

- `NotionClient` 네트워크 메서드와 `NotionSecretStore` read/write/delete는 `Future` 기반이다.
- `NotionSyncAdapter.push/archive/pull`은 `Future`, cursor는 opaque string이다.
- coordinator만 UI에 connect/sync/status/conflict 계약을 노출한다.
- Notion API 요청은 Bearer authorization과 version header를 사용하며 secret은 exception/state/log에 포함하지 않는다.
- canonical inbound write는 기존 `NotionCanonicalReconciler`와 Core service를 통과한다.

## 5. 리스크 & 미해결 가정

- Notion의 최신 data source/database 구조와 pagination은 실제 계정 schema에 따라 다르다. HTTP fixture test로 wire contract를 고정하고 live smoke는 사용자 token이 있는 opt-in acceptance로 분리한다.
- desktop secure store는 OS별 entitlement/package 요구가 있다. 지원 불가 환경에서는 파일 fallback 없이 fail closed한다.
- 실제 Notion database는 필요한 properties가 사전 생성돼 있다고 가정한다. 자동 database provisioning은 이번 범위가 아니다.
- 외부 token 없이 live Notion 성공을 증명할 수는 없다. mock HTTP 통합과 opt-in live acceptance를 구분해 보고한다.

## 6. 검증 방법

1. `dart format --output=none --set-exit-if-changed .`
2. `flutter analyze`
3. Notion HTTP, secure-store, adapter, coordinator, UI targeted tests
4. `flutter test`
5. `tool/font_provenance_check.sh`
6. `tool/secret_scan.sh`
7. 가능한 현재 host desktop build/plugin compile smoke
8. 수동/opt-in: Notion 편집 → pull → Git commit → Flutter 반영, Flutter 편집 → 동일 page update, 동시 편집 conflict

## 7. task 분할

1. **Notion async 계약과 실제 transport**
   - 작업: DATA_READER
   - 파일: Notion Core/HTTP/secret/config/coordinator와 관련 tests
   - 검증: targeted tests, analyzer
2. **전역 typography·통합 shell·Notion UI**
   - 작업: UI_INTEGRATION_READER
   - 파일: `lib/ui/*`, UI tests
   - 검증: typography invariant, navigation/sync/conflict widget tests
3. **composition·문서·통합**
   - 작업: ORCHESTRATOR
   - 파일: `lib/main.dart`, exports/dependencies/platform config, 최종계획 문서
   - 검증: full format/analyze/test/secret scan
4. **독립 스펙·품질 검수**
   - 작업: 각 모듈의 비작업 참여자
   - 검증: 설계 대비 누락/과구현, secret·Git 정본·commit-before-ack 불변조건

## 8. 구현·검수 결과

- Core 요구 1~3은 기존 ENV/Agent, Match, Recall 구현을 보존했고 전체 회귀 테스트로 재검증했다.
- Notion port를 async/opaque cursor로 전환하고 실제 HTTP client, OS secure store, local config, explicit sync coordinator를 연결했다.
- 동일 timestamp edit는 inclusive overlap 후 acknowledged revision dedupe로 처리한다.
- 일반 push는 foreign edit를 보호하며, 사용자가 검토한 `Keep Git`만 canonical ID별 explicit overwrite 경로를 사용한다.
- Flutter는 통합 shell과 Notion setup/sync/conflict 화면을 제공하고 모든 Material text role을 D2Coding 16pt로 통일했다.
- Objective database mapping 누락과 Keep Git 반복 conflict는 독립 검수에서 BLOCK된 뒤 교정·회귀 테스트를 추가했다.
- 후속 재검수(2026-07-24): 독립 코드 검증에서 `MatchService.propose`(manual/agent)가 서비스·테스트에만 존재하고 앱에서 호출되지 않아 요구2의 "사용자가 매칭하거나 agent가 매칭"이 실제로는 도달 불가능한 결함을 발견했다. Match 화면에 사용자 수동 매칭 생성(`New match` 다이얼로그 → `propose(mode: manual, actorType: user)`)과 agent 자동매칭(`Auto-match` → label 용어 겹침 heuristic으로 근거·신뢰도를 채운 `propose(mode: agent)`, 검토 게이트 유지를 위해 `proposed` 상태로 제안)을 배선하고, `subjectCandidates`/`targetCandidates`/`autoMatch` core API와 core·widget 회귀 테스트 4건을 추가했다.
- 최종 실행 결과: format PASS, analyze PASS, Flutter 148 tests PASS, font provenance PASS, secret scan PASS, golden 갱신(Match 화면 상단 액션 2개 추가).
- macOS debug artifact는 Keychain entitlement에 필요한 development signing identity가 없어 unsigned 환경에서 실패했다. secure token을 파일로 fallback하지 않으며 signed build와 live Notion credential smoke를 외부 acceptance로 유지한다.

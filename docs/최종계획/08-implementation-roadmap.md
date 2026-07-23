# 구현 로드맵과 Agent 작업 지침

<!-- 최종 계획 문서 -->

## 구현 원칙

- 기존 dirty worktree와 `ai/prompt-task`를 보존한다.
- 새 시스템은 `workdb/`, `core/`, `apps/`에서 병행 구축한다.
- 각 단계는 실행 가능한 작은 vertical slice로 끝낸다.
- GUI가 정본을 직접 편집하지 않고 Worklog Core를 사용한다.
- 보안과 schema 검증을 마지막에 덧붙이지 않고 첫 단계부터 적용한다.
- 모든 Task는 세 under-claw 스킬 pipeline을 사용하고 provider/model 차이는 adapter가 흡수한다.
- installer와 uninstaller는 install manifest 밖의 사용자 파일을 변경하지 않는다.

## Phase 0: ADR과 스키마

산출물:

- 기술 ADR
- Domain, Milestone, Objective, Task, Knowledge, Reference, Event JSON Schema
- immutable ControlRequest/ControlDisposition, Operation, SkillInvocation, repository auth와 skill pipeline policy
- ULID 생성 규약
- 상태 전이 표
- relation registry
- 예제 fixture

완료 조건:

- valid/invalid fixture 테스트
- ID 중복과 잘못된 참조 검출
- Task 의존성 순환 검출

## Phase 1: Worklog Core와 CLI

명령 초안:

```text
worklog doctor
worklog sync
worklog domain list|create|show|update
worklog milestone list|create|show|update
worklog objective list|create|show|update|link
worklog task list|create|show|update
worklog task claim|heartbeat|release
worklog task transition
worklog task start|pause|resume|cancel|complete
worklog prompt generate-meta|approve|diff
worklog skill doctor|repair
worklog knowledge add|search|link
worklog reference add|list|show|link|extract
worklog context build
worklog index rebuild|status
```

완료 조건:

- clean machine에서 단일 바이너리 실행
- SQLite 자동 생성·삭제 후 복원
- 기본 CRUD와 schema 검증
- Task state machine
- ControlDisposition compare-and-create, operation 재진입과 duplicate Run 방지
- 로컬 file lock

## Phase 2: GitHub 동기화와 보안

산출물:

- Git clone/fetch/commit/push adapter
- GitHub OAuth/credential storage
- AuthProvider spike·선정 gate와 repository bootstrap
- semantic conflict model
- remote claim
- security scanner
- redacted structured logs

완료 조건:

- 두 환경에서 서로 다른 Task 변경 자동 병합
- 동일 필드 충돌 탐지
- 중복 claim 방지
- 민감정보 push 차단
- 로그 secret leakage 테스트

## Phase 3: Desktop GUI MVP

화면:

- 로그인
- GitHub 최초 연결
- Home
- Domain/Milestone
- Task list/Kanban
- Task overview
- Task 생성·수정·시작·일시중지·재개·중단·완료 제어
- Draft/Meta 편집과 승인
- 세 스킬 pipeline과 loop 회차 진행상태
- 자동 생성 후보함과 자동 처리 policy
- Knowledge list
- 동기화 상태

완료 조건:

- macOS와 Windows에서 동일 저장소 사용
- GUI만으로 Domain → Milestone → Task 생성
- Draft 변경 후 Meta stale 표시
- 승인 전 실행 차단
- Agent ACK 전후 상태 구분
- 앱 재시작과 오프라인 Draft 복구

## Phase 4: Agent 실행

산출물:

- Environment/Agent 등록
- Task selector
- context pack builder
- Run/heartbeat
- Hermes adapter
- 파생·후속 Task generator
- provider-neutral runner adapter와 필수 세 스킬 pipeline

완료 조건:

- headless Linux에서 자동 Task 선택·claim
- 승인 Meta만 실행
- Knowledge와 Run 기록
- generation policy와 중복 방지
- GUI에서 Agent 상태 확인
- invocation 순서와 reviewer gate 검증

## Phase 5: 설치 패키지

산출물:

- macOS signed/notarized installer
- Windows signed installer
- Linux AppImage
- headless binaries
- 세 스킬 bundle, host adapter와 install manifest
- signed update manifest
- 자동 업데이트

완료 조건:

- 개발도구 없는 VM smoke test
- 설치파일만으로 앱 실행
- 패스워드 로그인
- 최초 target repository와 repository password 설정
- SQLite 무설정 자동 관리
- uninstall과 local-data 유지 선택
- install manifest 밖 파일 보존

## Phase 6: 기존 데이터 마이그레이션

절차:

1. 기존 일자별 블록 parser
2. 빈 template block 제외
3. 요구사항을 Draft로 변환
4. 기존 Meta Prompt 분리
5. PT ID를 `legacy_ids`로 보존
6. Domain/Milestone 후보 보고서 생성
7. dry-run과 diff
8. 사용자 승인
9. 신규 정본 생성
10. 기존 파일 archive

민감정보 검사 전에는 변환 결과를 push하지 않는다.

## 초기 작업 백로그

### Core foundation

- [ ] Go module과 디렉터리 생성
- [ ] error code와 JSON Lines RPC 규약 정의
- [ ] ULID 생성기
- [ ] atomic file writer
- [ ] cross-platform application data path
- [ ] local process lock

### Schema

- [ ] Domain schema
- [ ] Milestone schema
- [ ] Objective schema
- [ ] Task schema
- [ ] Prompt frontmatter schema
- [ ] Knowledge schema
- [ ] Reference schema
- [ ] Event/Claim schema
- [ ] registry validator
- [ ] cross-reference validator

### Index

- [ ] embedded SQLite adapter
- [ ] metadata table
- [ ] entity projection
- [ ] FTS5
- [ ] relation reverse index
- [ ] incremental indexer
- [ ] corruption recovery

### Security

- [ ] Argon2id verifier loader
- [ ] login throttling
- [ ] memory/session cleanup
- [ ] OS credential store abstraction
- [ ] log redaction
- [ ] repository security scanner
- [ ] signed update manifest verification

### Sync and concurrency

- [ ] Git adapter
- [ ] GitHub API adapter
- [ ] offline operation journal
- [ ] remote claim
- [ ] heartbeat and expiry recovery
- [ ] edit lease
- [ ] semantic merge

### GUI

- [ ] Flutter desktop shell
- [ ] lock screen
- [ ] onboarding
- [ ] Domain/Milestone navigator
- [ ] Objective/Knowledge/Reference tabs
- [ ] Task editor
- [ ] Draft/Meta split editor
- [ ] Knowledge cards
- [ ] Kanban
- [ ] sync/conflict UI
- [ ] environment management
- [ ] Task control center와 ControlRequest ACK
- [ ] 자동 생성 후보함과 자동 처리 policy
- [ ] 세 스킬 pipeline/loop progress
- [ ] repository 연결·전환·password 변경

### Skill runtime과 installer

- [ ] versioned three-skill bundle manifest
- [ ] 세 스킬 invocation과 순서 검증
- [ ] Codex/Claude/Gemini/Hermes host adapter
- [ ] generic runner contract test
- [ ] AuthProvider API/권한/기밀성/cross-device/실패복구 spike와 선정 gate
- [ ] platform installer와 headless bootstrap
- [ ] install ownership manifest와 update rollback
- [ ] app-only/runtime/full uninstall
- [ ] clean VM cross-platform smoke test

## Agent가 작업을 시작할 때

1. `AGENTS.md`와 이 문서 전체를 읽는다.
2. `git status --short`로 사용자 변경을 확인하고 보존한다.
3. 현재 Phase와 선행 완료 조건을 확인한다.
4. 하나의 bounded Task만 claim한다.
5. schema 또는 공개 Core contract 변경은 ADR을 먼저 갱신한다.
6. 실제 인증값이나 고객정보를 fixture에 넣지 않는다.
7. 관련 테스트와 cross-platform 영향을 확인한다.
8. 완료 시 변경, 검증, 미확정 사항과 후속 Task를 기록한다.

## 첫 구현 권장 Task

첫 Task는 GUI가 아니라 다음 vertical slice다.

> Domain, Milestone, Objective, Knowledge, Reference와 Task fixture를 읽어 검증하고 자동 SQLite 인덱스를 만든 뒤 `worklog task list`로 조회한다.

이 Task가 완료되면 다음 Task로 macOS/Windows 공통 Flutter shell에서 같은 목록을 표시한다. 이 순서를 지키면 GUI와 CLI가 서로 다른 데이터 규칙을 구현하는 문제를 예방할 수 있다.

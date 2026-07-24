# 시스템 아키텍처

<!-- 최종 계획 문서 -->

## 구성요소

```text
┌───────────────────────────────────────────────────────────┐
│                    GitHub Private Repository               │
│  workdb/ 정본 · schema · registry · events · claims       │
└──────────────────────────────┬────────────────────────────┘
                               │ Git / GitHub API
          ┌────────────────────┼────────────────────┐
          │                    │                    │
┌─────────▼─────────┐ ┌────────▼────────┐ ┌────────▼─────────┐
│ Worklog Studio    │ │ Worklog Studio │ │ worklog CLI      │
│ macOS             │ │ Windows/Linux  │ │ Hermes / CI      │
└─────────┬─────────┘ └────────┬────────┘ └────────┬─────────┘
          └────────────────────┼────────────────────┘
                               │
                     ┌─────────▼─────────┐
                     │ Worklog Core      │
                     │ validation        │
                     │ state machine     │
                     │ sync / claim      │
                     │ control requests  │
                     │ skill pipeline    │
                     │ index / security  │
                     └─────────┬─────────┘
                               │
             ┌─────────────────┼─────────────────┐
             │                 │                 │
       local Git copy    local SQLite      OS secure store
```

## 기술 선택

### GUI

- Flutter Desktop
- macOS, Windows, Linux 단일 UI 코드베이스
- 브라우저와 localhost 서버 없이 실행
- Material 3 기반이되 각 OS 단축키와 창 동작을 적용

### Core

권장 구현은 Go 기반 독립 Core와 CLI다.

- CGO가 필요 없는 embedded SQLite 사용
- OS별 단일 바이너리 배포
- GUI는 안정된 local IPC 또는 FFI adapter로 Core를 호출
- CLI와 GUI가 동일한 validation, 상태 전이, sync 로직을 사용
- GUI는 Task 시작·중지 상태를 직접 덮어쓰지 않고 Core에 idempotent ControlRequest를 제출

첫 구현에서 FFI 복잡도가 크면 GUI가 Core 프로세스를 자식 프로세스로 실행하고 JSON Lines RPC로 통신한다. localhost TCP 포트는 사용하지 않는다.

### 정본

- YAML: 상태, ID, 관계와 옵션
- Markdown: Prompt와 Knowledge 본문
- JSON Schema: 정본 구조 검증
- Git: 변경 이력과 동기화

### 스킬 실행 runtime

Core의 orchestration contract와 Agent provider adapter를 분리한다.

```text
Worklog Core
└── Skill Runtime
    ├── under-claw-meta-prompt
    ├── under-claw-jarvis-plan-loop
    │   └── under-claw-jarvis-plan
    └── Runner Adapter
        ├── Codex
        ├── Claude
        ├── Gemini
        ├── Hermes
        └── generic command
```

Task에는 provider model ID 대신 필요 capability와 실행 정책을 저장한다. 구체 runner와 model 선택은 Environment/Agent registry와 실행 시점 정책이 결정한다. 상세 계약은 [세 스킬 오케스트레이션](09-skill-orchestration.md)을 따른다.

### 파생 저장소

- SQLite: FTS5, 관계 역인덱스, 집계와 빠른 조회
- agentmemory: 선택적 BM25·vector·concept graph 회상
- 둘 다 정본으로 간주하지 않는다.

## 저장소 구조

```text
workdb/
├─ schemas/
├─ domains/
├─ milestones/
├─ objectives/
├─ tasks/
├─ knowledge/
├─ references/
├─ matches/
├─ events/
├─ control-requests/
├─ control-dispositions/
├─ claims/
├─ config/
│  ├─ environments.yaml
│  ├─ agents.yaml
│  ├─ repository-auth.yaml
│  ├─ skill-pipeline.yaml
│  ├─ capabilities.yaml
│  └─ relation-types.yaml
└─ migrations/

apps/
└─ worklog_studio/

core/
└─ worklog/

docs/
```

## 로컬 자동 관리

운영체제별 application data 경로 아래에 다음을 자동 생성한다.

```text
WorklogStudio/
├─ repository/
├─ cache/index.sqlite
├─ cache/index.sqlite.tmp
├─ locks/
├─ runtime/
├─ logs/
└─ state.json
```

- macOS: `~/Library/Application Support/WorklogStudio/`
- Windows: `%LOCALAPPDATA%\WorklogStudio\`
- Linux: `~/.local/share/worklog-studio/`

사용자는 경로, DB와 runtime을 직접 관리하지 않는다.

## 자동 인덱스 수명주기

SQLite 메타 테이블은 다음 값을 보관한다.

```text
schema_version
indexer_version
indexed_git_commit
source_fingerprint
indexed_at
```

Core 시작 순서:

1. 로컬 process lock 획득
2. 정본 repository 확인 또는 clone
3. 현재 Git commit과 dirty 파일 확인
4. 인덱스 호환성 확인
5. 변경 파일 증분 반영 또는 전체 재생성
6. integrity check
7. 임시 DB를 atomic rename
8. 사용자 명령 실행

DB가 없거나 손상되면 사용자 확인 없이 Git 정본에서 재생성한다. 사용자 작성 데이터는 SQLite에만 저장하지 않는다.

## 동기화

### 일반 경로

```text
remote fetch
→ local semantic changes 생성
→ schema/security validation
→ remote head 재확인
→ rebase/semantic merge
→ commit
→ push
→ local index 반영
```

### 충돌

- 서로 다른 엔티티 파일: Git 자동 병합
- 같은 Task의 별도 append-only Event: 자동 병합
- 같은 구조화 필드: semantic conflict
- 같은 Prompt revision 본문: 사용자에게 diff 제공

GUI는 Git conflict marker를 직접 보여주지 않고 필드·문서 단위 해결 화면을 제공한다.

## Identity

Environment와 Agent를 분리한다.

```text
Environment: 물리·논리 실행 장소
Agent: 해당 환경에서 작업하는 런타임
Run: Agent가 Task를 한 번 실행한 기록
```

환경은 registry에 등록하지만 실제 credential과 토큰은 로컬 OS secure store에만 보관한다.

## Repository별 인증

이 문서는 경계만 정의한다. 인증 provider 선정 gate, 검토된 PAKE 또는 표준 외부 인증 protocol, 최초 setup, cross-device와 실패 복구의 normative source는 [로그인과 보안](06-security-auth.md)이다. provider는 구현 spike 통과 전 미선정 상태이며 Git 정본에는 실제 password나 verifier를 저장하지 않는다.

## Task control plane

GUI 또는 CLI의 `start`, `pause`, `resume`, `cancel`, `complete` 명령은 append-only ControlRequest를 만든다. 원격 Agent가 ACK하기 전까지 Task 화면에는 `요청됨`으로 표시한다.

```text
GUI command
→ Core precondition/revision 검사
→ immutable ControlRequest 기록·동기화
→ Agent poll/receive
→ request별 고정 경로에 immutable ACK/reject/withdraw ControlDisposition compare-and-create
→ Task 실제 상태 전이
→ 모든 환경 UI 갱신
```

Run 생성·ACK 주체·철회 경합의 normative source는 [Task와 Multi-agent 워크플로](04-task-workflow.md)와 [정본 데이터 모델](03-data-model.md)이다.

## 확장 경계

동시 편집과 Agent 수가 GitHub 기반 claim으로 감당하기 어려워지면 별도 coordinator를 추가할 수 있다. 이때에도 정본 포맷과 Core API는 유지한다. PostgreSQL 또는 graph DB는 초기 필수 구성요소가 아니다.

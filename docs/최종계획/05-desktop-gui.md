# 데스크톱 GUI

<!-- 최종 계획 문서 -->

## 제품 형태

`Worklog Studio`는 Flutter Desktop 기반 로컬 앱이다.

- macOS, Windows, Linux 지원
- 브라우저 업무 화면 없음
- localhost 서버 없음
- 같은 Worklog Core를 GUI와 CLI가 공유
- Git, YAML, SQLite와 ULID는 기본 화면에서 숨김
- 모든 텍스트는 앱에 포함된 D2Coding 16pt를 사용하고 굵기·색·행간으로 정보 위계를 표현
- 공개적으로 관찰 가능한 Orca/Warp 계열의 dense navigation, master/detail, status 패턴을 자체 design token으로 구현

## Notion 동시 관리

Notion은 선택 가능한 관리 화면이지만 Git 정본을 대체하지 않는다.

- Integration token은 OS secure store에만 저장하고 화면·Git·SQLite·로그에는 남기지 않는다.
- Domain, Milestone, Objective, Task, Knowledge, Reference, Environment, Agent와 Match database ID를 local config에 연결한다.
- 초기 버전은 사용자가 누르는 `Sync now`만 제공하며 background sync는 하지 않는다.
- Flutter 변경은 canonical ID로 기존 Notion page를 갱신하고, Notion 변경은 Core validation과 Git commit 성공 후에만 cursor를 acknowledge한다.
- 동시 편집은 blind overwrite하지 않고 충돌 화면에 표시한다.
- Notion database에는 `title` property와 나머지 동기화 property를 받을 수 있는 schema가 준비돼 있어야 한다.

## 정보 구조

```text
Domain
└── Milestone
    └── Task
        ├── Prompt
        ├── Knowledge
        ├── Relations
        ├── Runs
        └── Artifacts
```

## 주요 화면

### 잠금 화면

- 현재 연결된 target repository 이름
- 사용자명 입력 없음
- 패스워드 입력 한 개
- 로그인 버튼
- 오류 시 값과 내부 검증정보를 표시하지 않음
- 반복 실패 시 지연

### 초기 연결

- GitHub 인증
- 접근 가능한 target repository 선택 또는 새 Worklog repository 초기화
- auth policy가 없으면 새 repository password와 확인 입력
- auth policy가 있으면 해당 repository password 입력
- 로컬 clone과 인덱싱 진행률
- Environment 이름 확인

초기 연결 후에는 일반적으로 다시 표시하지 않는다.

Private repository는 인증 전 내용을 읽을 수 없으므로 새 기기의 최초 순서는 `GitHub 인증 → repository 선택 → password 입력`이다. 한 번 연결된 기기는 repository locator와 정책 cache를 OS secure store에서 읽어 password 잠금 화면부터 시작한다.

### Home

- 최근 Domain과 Milestone
- 오늘 실행 가능한 Task
- 진행 중·차단·Meta 필요 Task
- 다른 환경에서 실행 중인 Task
- 시작·일시중지·재개·중단 요청 대기 Task
- 세 스킬 pipeline의 현재 단계와 loop 회차
- 동기화와 보안 검사 상태

### Domain·Milestone

- 좌측 트리 탐색
- `주요 목표`, `사전 지식`, `참고자료`를 분리한 탭
- 주요 목표와 성공 기준 항목 편집
- 기존 Objective, Knowledge와 Reference 검색·연결
- 새 사전 지식과 참고자료를 현재 화면에서 바로 작성
- 목표일과 우선순위
- 진행률, 완료·차단 Task 집계
- 새 Task 생성

Domain과 Milestone 편집 화면:

```text
[개요] [주요 목표] [사전 지식] [참고자료] [Task] [진행 현황]
```

주요 목표:

- 목표별 상태, 우선순위와 성공 기준
- 상위 Domain 목표와 Milestone 목표 연결
- 목표에 기여하는 Task와 완료율
- 목표를 선택한 상태에서 Task 자동 생성

사전 지식:

- 직접 작성
- 기존 Knowledge 검색·연결
- 확인된 사실, 가정, 제약, 결정 등 유형 선택
- 관련 Objective와 Reference 연결

참고자료:

- 파일 선택 또는 앱으로 끌어놓기
- 저장소 상대경로, 공개 URL, 문서와 이슈 참조
- 자료의 용도와 읽을 범위 작성
- Agent에게 컨텍스트로 제공할지 설정
- 자료에서 Knowledge 추출 요청

### Task

탭:

```text
[개요] [프롬프트] [기억] [관계] [실행 기록] [산출물]
```

개요:

- 제목, 상태, 우선순위
- Domain과 Milestone
- 실행 환경 selector
- 파생·후속 Task 자동 생성 option
- 선행 조건
- 현재 edit lease/execution claim

프롬프트:

```text
┌───────────────────────┬───────────────────────┐
│ Draft                 │ Meta                  │
│ 편집/미리보기         │ 편집/미리보기         │
├───────────────────────┴───────────────────────┤
│ Draft v3 · Meta v2 · Meta 재생성 필요         │
│ [diff] [Meta 생성] [승인] [시작]              │
└───────────────────────────────────────────────┘
```

- Markdown 편집
- 자동 저장과 복구
- revision 표시
- Draft 변경 시 Meta stale 경고
- 승인 전후 diff
- 승인된 최신 Meta가 없으면 실행 버튼 비활성화
- Meta 생성 시 `under-claw-meta-prompt` invocation 상태와 결과 표시

기억:

- 확인된 사실
- 결정
- 가정
- 미확정 쟁점
- 제약
- 실패
- 인수인계

파일 목록 대신 의미별 카드와 검색을 기본으로 한다.

관계:

- 목록과 소형 dependency graph
- drag로 관계 추가
- 순환 의존성 경고
- 파생·후속 Task 생성 근거 표시

실행 기록:

- Environment와 Agent
- 시작·마지막 heartbeat·완료 시각
- 현재 단계와 상태
- 검증 결과
- 생성된 Knowledge와 Task
- Task 생성에 사용된 Objective, Knowledge와 Reference
- `under-claw-meta-prompt`, `under-claw-jarvis-plan-loop`, 회차별 `under-claw-jarvis-plan` invocation
- loop 점수, reviewer verdict, 종료 사유

### Task 제어 센터

Task 상세 상단은 상태에 맞는 명령만 활성화한다.

```text
상태: 진행 중 · Ubuntu Hermes · 마지막 heartbeat 12초 전
Pipeline: loop round 2 · under-claw-jarvis-plan 검수

[일시중지] [중단] [완료 요청]
```

상태별 제어:

- `ready`: 시작
- `ready · 시작 요청됨`: 요청 철회
- `claimed`/`in_progress`: 일시중지, 중단, 완료 요청
- `paused`: 재개, 중단
- `blocked`: 재개 조건 작성, 중단, 근거가 있는 완료 요청
- `completed`/`cancelled`: 읽기 전용, 재작업 Task 생성

버튼을 누르면 즉시 완료 상태로 바꾸지 않고 다음을 표시한다.

```text
일시중지 요청 전송됨
대상: Ubuntu Hermes
요청 시각: ...
[요청 철회]
```

`요청 철회`는 `withdraw_control_request`를 호출하며 실행 중인 Task를 멈추는 `중단`과 다르다. Agent ACK와 경합해 ACK가 먼저 성공하면 철회 실패를 표시하고, 사용자가 원하면 별도 중단 요청을 보낸다.

Agent ACK가 오면 `paused`, reject면 코드와 사람이 이해할 수 있는 이유, timeout이면 재시도 버튼을 표시한다. 동일 요청 재시도는 같은 idempotency key를 사용한다.

완료 요청 화면은 성공 기준, 실행 검증, reviewer verdict, 산출물과 남은 쟁점을 보여준다. 강제 완료는 경고와 사유 입력을 요구하고 Event에 남긴다.

### 자동 생성·처리 관리

Milestone과 Task에서 다음 정책을 GUI로 설정한다.

- 파생 Task 자동 생성
- 후속 Task 자동 생성
- 후보 생성만 / Meta까지 생성 / 승인된 범위에서 자동 시작
- generation depth와 최대 동시 실행 수
- 허용 Environment와 capability
- 자동 시작 허용 시간대

`자동 생성함`은 생성된 Task 후보를 목표·근거별로 보여준다.

```text
후보 Task: 프론트 응답 타입 갱신
기여 목표: OBJ-...
근거: KNW-... · REF-...
중복 검사: 통과

[승인 후 Meta 생성] [수정] [거부]
```

자동 처리된 Task도 세 스킬 pipeline 진행상태와 중단 제어를 동일하게 제공한다.

### Task board

- Milestone별 Kanban
- 상태, 우선순위, 환경, Agent, Meta 상태 필터
- drag 시 Core 상태 전이 검증
- 실행 불가능한 이동은 이유를 표시하고 거부

### 동기화와 충돌

일반 상태는 우측 상단 한 줄로 표시한다.

```text
동기화됨 / 동기화 중 / 오프라인 / 충돌 / 보안 검사 실패
```

동일 필드 충돌은 의미 단위로 해결한다.

```text
우선순위
MacBook: high
Windows: low

[MacBook 값] [Windows 값]
```

Git conflict marker를 일반 사용자에게 보여주지 않는다.

### 환경 관리

- 등록된 Mac, Windows, Linux, 서버
- OS와 capability
- 마지막 연결 시각
- 환경 이름 변경
- 비활성 환경 revoke
- 환경별 Agent 목록

credential과 실제 token은 표시하지 않는다.

### Repository 연결 관리

- 연결된 repository 목록과 현재 target
- repository별 auth policy version과 마지막 sync 시각
- 다른 repository 연결
- repository password 변경
- 이 기기에서 repository 연결 해제
- 손실된 환경 credential revoke 안내

repository를 전환하면 각 repository의 별도 local clone, SQLite projection, auth session을 사용한다. password나 verifier는 화면·진단 export에 표시하지 않는다.

## 사용자에게 숨길 항목

- 정본 파일 경로와 YAML
- SQLite 파일
- schema/index version
- claim/Event 내부 파일
- Git branch와 low-level conflict
- 인증 verifier와 token

고급 진단 화면에서 ID, commit, 로그 위치를 확인할 수 있지만 비밀값은 항상 마스킹한다.

## 단축키

- 새 Task: `Cmd/Ctrl+N`
- 전체 검색: `Cmd/Ctrl+K`
- 저장: `Cmd/Ctrl+S`
- 동기화: `Cmd/Ctrl+Shift+S`
- Task 실행: 명시적 확인이 필요한 단축키 조합

macOS와 Windows/Linux의 표준 키 관례를 따른다.

## 접근성

- 모든 기능을 키보드로 수행 가능
- 상태를 색상만으로 구분하지 않음
- 시스템 글자 크기와 고대비 대응
- 비동기 작업의 진행 상태와 실패 이유 제공

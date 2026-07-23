# 제품 요구사항

<!-- 최종 계획 문서 -->

## 사용자

- 업무 Domain과 Milestone을 정의하는 저장소 소유자
- GUI에서 Task와 프롬프트를 작성하는 사용자
- Task를 생성·수행하는 Codex, Claude, Hermes 등의 Agent
- GUI 없이 CLI만 실행하는 서버와 CI 환경

## 핵심 개념

### Domain

장기적으로 유지되는 업무·프로젝트 범위다. Domain은 여러 Milestone을 가진다.

### Milestone

Domain 아래의 목표 단위다. 목표, 성공 기준, 우선순위, 목표일과 진행 상태를 가진다.

### Objective

Domain 또는 Milestone이 달성해야 하는 주요 목표다. 본문 속 문장이 아니라 고유 ID, 우선순위와 성공 기준을 가진 독립 엔티티로 관리한다. Task 자동 생성과 완료 판단의 기준이 된다.

### Task

Agent가 실제로 점유하고 실행하는 작업 단위다. 사용자가 직접 만들거나 Agent가 파생·후속 Task로 생성할 수 있다.

### Prompt Draft

사용자 또는 Agent가 작성한 원 요구사항이다.

### Prompt Meta

Prompt Draft를 메타 프롬프팅한 실행용 프롬프트다. Task 실행은 최신 Draft revision에 대응하고 승인된 Meta Prompt만 사용한다.

### Knowledge

Task 수행에 필요한 요구사항, 확인된 사실, 가정, 미확정 쟁점, 결정, 제약, 실패, 절차와 인수인계 요약이다. 하나의 Task에 여러 Knowledge가 연결될 수 있고 하나의 Knowledge를 여러 Task가 공유할 수 있다.

### Reference

Domain 또는 Milestone을 이해하고 Task를 수행할 때 참고할 문서, 저장소 경로, 첨부파일, 공개 URL, 내부 문서의 마스킹된 참조다. 자료 자체와 그 자료에서 추출·확인된 Knowledge를 구분한다.

## 주요 사용자 시나리오

### GUI 사용자

1. 설치파일로 Worklog Studio를 설치한다.
2. 최초 setup에서 GitHub Private 저장소를 선택하고 해당 저장소용 패스워드를 설정한다.
3. 이후 앱을 열 때는 연결된 저장소의 패스워드만 입력한다.
4. Domain을 선택하고 Milestone 목표를 작성한다.
5. Task 초안을 작성한다.
6. Meta Prompt를 생성·검토·승인한다.
7. 실행 환경과 자동 파생 정책을 선택한다.
8. Task를 시작하고 필요하면 일시중지·재개·중단한다.
9. 완료 조건과 검수 결과를 확인해 완료 처리하거나 Agent가 가져가도록 `ready` 상태로 둔다.
10. 진행 상황, 스킬 실행 단계, Knowledge와 파생 Task를 GUI에서 확인·관리한다.

### Agent

1. Core가 저장소와 인덱스를 자동 동기화한다.
2. 실행 가능한 Task를 검색한다.
3. 최신 Meta Prompt와 세 스킬 pipeline, 선행 조건을 검증한다.
4. 원격 execution claim을 획득한다.
5. 관련 Knowledge로 context pack을 구성한다.
6. Task를 실행하고 heartbeat와 Event를 기록한다.
7. 영구 보존할 사항을 Knowledge로 기록한다.
8. 정책이 허용하면 Domain 또는 Milestone Objective에 부합하는 파생·후속 Task를 만든다.
9. 검증 결과와 산출물을 기록하고 Task를 완료한다.

## 기능 요구사항

### Domain·Milestone

- 생성, 수정, archive
- Domain 주요 목표와 Milestone 주요 목표의 항목별 관리
- 주요 목표별 성공 기준, 우선순위와 상태
- 사전 지식의 직접 작성 및 기존 Knowledge 연결
- 참고자료 등록 및 기존 Reference 연결
- Reference에서 추출된 Knowledge의 출처 추적
- 상태, 우선순위, 목표일
- 진행률과 차단 Task 집계

### Task

- 목록, Kanban, 검색, 필터
- 전역 고유 ID 자동 발급
- 상태 전이 검증
- 선행, 차단, 파생, 후속, 관련, 대체 관계
- 허용·선호 실행 환경과 필요 capability
- 파생 Task 자동 생성 여부
- 후속 Task 자동 생성 여부
- 생성 근거 Objective, Knowledge와 Reference
- Agent execution claim과 사용자 edit lease
- GUI의 시작·일시중지·재개·중단·완료 ControlRequest
- immutable ControlRequest와 별도 immutable ControlDisposition으로 ACK, 거부, 철회, timeout과 최종 상태 분리
- 자동 Task 생성 후보 검토·승인·거부와 즉시 자동 처리 정책

### Prompt

- Draft와 Meta 분리
- 각각의 revision과 변경 이력
- Meta Prompt의 기반 Draft revision 기록
- Draft 변경 시 Meta 자동 stale 처리
- Meta 생성, diff, 승인
- 승인된 최신 Meta만 실행 가능
- Draft마다 `under-claw-meta-prompt`를 명시적으로 호출한 생성 기록

### 실행 스킬

- 세 스킬을 설치 bundle의 기본 구성으로 제공
- Task Draft → Meta 변환은 `under-claw-meta-prompt`
- Task 실행 전체는 `under-claw-jarvis-plan-loop`
- loop의 각 구현 회차는 `under-claw-jarvis-plan`
- 각 호출의 skill ID, bundle version, 입력 revision, 결과와 종료 사유 기록
- Codex, Claude, Gemini, Hermes와 generic runner가 같은 Core contract 사용
- Task 스키마와 workflow가 특정 provider 또는 model ID를 요구하지 않음

### Knowledge

- 유형별 작은 노드 작성
- Domain, Milestone, Objective, Task, Reference, Knowledge, Run과 연결
- supports, contradicts, supersedes, derived_from 관계
- 검색과 Task별 context pack 생성
- 인수인계 요약

### 동기화

- GitHub Private 저장소 자동 clone, pull, commit, push
- 네트워크 단절 시 로컬 작업 후 재동기화
- 충돌이 없는 변경은 자동 병합
- 동일 의미 필드 충돌은 GUI에서 값 단위로 해결
- 민감정보 발견 시 push 차단

### 로컬 인덱스

- 설치와 설정 없이 자동 생성
- schema/indexer version 관리
- Git 변경분 증분 반영
- 손상 또는 불일치 시 전체 자동 재생성
- 로컬 동시 실행 file lock

### 설치·초기 설정·제거

- macOS, Windows, Linux는 서명된 설치파일 하나로 설치
- headless 환경은 단일 bootstrap 실행파일 또는 검증된 install script로 설치
- 최초 setup에서 GitHub 인증, target repository 선택, Environment 이름, 새 repository password 설정
- 감지된 Agent host에 세 스킬과 Worklog adapter 자동 설치
- 재설치와 업데이트는 기존 사용자 설정을 보존
- 앱만 제거와 로컬 데이터·credential까지 지우는 완전 제거를 구분
- uninstall은 install manifest에 기록된 파일과 설정만 제거
- 실제 password, verifier와 token은 Git·설치 artifact·로그에 저장하지 않음

## 비기능 요구사항

- macOS ARM64/x64, Windows x64, Linux x64 우선 지원
- Linux ARM64와 Windows ARM64는 후속 지원
- 일반 조회와 화면 전환은 로컬 데이터 기준 300ms 이내를 목표로 한다.
- 앱 종료나 강제 종료 후에도 정본 데이터가 손상되지 않아야 한다.
- 네트워크가 없어도 조회와 신규 Draft 작성이 가능해야 한다.
- 앱은 localhost 웹 서버를 요구하지 않는다.
- 실제 패스워드, GitHub 토큰과 비밀값을 로그에 기록하지 않는다.
- 기존 저장소의 민감정보 검사 정책을 모든 push 경로에 적용한다.

## 범위 밖

- 불특정 다수 사용자를 위한 SaaS
- 브라우저 기반 업무 화면
- GitHub를 대체하는 중앙 운영 DB
- 사용자 간 세밀한 역할 기반 권한관리
- 모바일 앱
- 첫 버전의 실시간 공동 문서 편집
- 공유 패스워드를 사용자별 권한관리나 GitHub 인증의 대체물로 사용하는 것

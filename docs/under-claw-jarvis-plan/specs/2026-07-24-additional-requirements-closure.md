# 추가 요구사항 충족 — 갭 클로저 설계

작성일: 2026-07-24 · 대상: `/Users/jsj/soruce/strong1133/under-claw-work`

## 배경

`docs/최종계획/00-최종계획.md`의 5개 추가요구는 이미 대부분 구현·테스트되어 있다(baseline: `flutter analyze` clean, 155 tests green). 4개 영역 독립 감사로 남은 구체 갭만 외과적으로 닫는다. Karpathy 원칙: 가정금지·단순성·외과적 변경·검증.

## 요구별 상태와 조치

### 요구1 — 데이터 구조 + Agent 환경 식별/별칭(수정 가능)
- 상태: Environment(불변 `machine_key`/`id` + 편집 가능 `alias`)는 CLI·UI 모두 완비, 테스트됨.
- 갭: Agent의 `kind`(hermes/claude/codex 등 런타임 구분자)가 등록 후 수정 불가(`setKind` 부재, UI read-only) → "수정 가능해야함" 위반.
- 조치 A:
  - `AgentRegistryService.setKind(id, kind)` 추가(빈 값 거부, lock 하 원자적 write).
  - `agent_screen.dart` Kind를 편집 가능 필드(TextField + Save)로 전환.
  - CLI `agent-rename`, `agent-set-kind` 추가.

### 요구2 — 참고자료/지식 매칭(사용자·agent·둘다)
- 상태: `Match`(MAT-) 정본 + 사용자 수동(New match) + agent 자동(Auto-match) + propose/approve/reject/revoke 완비, 테스트됨. **조치 없음.**

### 요구3 — agent 통합 기억 메모리
- 상태: Domain/Milestone/Task scope + 승인 Match 경유 교차-agent 회상, supersede/보안필터 완비.
- 갭: `contradictedBy`/`derivedFrom`가 계산되나 UI 미표시; "freshest-first" 주석과 달리 id 정렬.
- 조치 B: `_KnowledgeTile`에 contradicts/derived_from 렌더; `RecalledKnowledge.updatedAt` 추가 후 최신순 정렬(id tiebreak).

### 요구4 — Flutter Orca/Warp 카피 + 16pt D2Coding 일원화
- 상태: D2Coding 번들·전역 기본, 전 슬롯 16pt, dense sidebar + master/detail, Warp/Orca 계열 다크 토큰.
- 갭: Warp/Orca 시그니처인 하단 status bar 부재; `main.dart:135` raw `Colors.red`.
- 조치 C: `UnifiedWorkspaceShell`에 지속 status bar 추가; 색상 토큰화(`AppTokens.statusDanger`).
- 유지: 대규모/주관적 리팩터(FAB·중첩 AppBar 제거)는 위험 대비 이득이 낮아 이번 범위 밖(보고서에 명시).

### 요구5 — Notion 동시 관리
- 상태: 9개 타입 push, 양방향 pull+Git-commit-before-ack, 충돌 화면, 실 REST + OS secret store.
- 갭: Knowledge/Reference의 **body**(자료의 실체)가 push/reconcile 모두 누락 → Notion에서 제목/상태만 관리 가능.
- 조치 D: `NotionEntityMapper.fromCanonical`에 `body` 포함(graph kinds); `_applyGraph`가 inbound `body`를 write-back(존재·상이할 때만).
- 유지: Match `review_state`는 Git 정본 authoritative(감사 안전 불변식) — Notion 편집은 명시적 conflict로 남긴다.

## 검증
`dart format`, `flutter analyze`, 신규/기존 `flutter test`(setKind, 관계 렌더, 최신순, Notion body 왕복), 시크릿 스캔.

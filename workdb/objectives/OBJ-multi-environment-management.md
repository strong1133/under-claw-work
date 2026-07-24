---
schema_version: 1
id: OBJ-multi-environment-management
type: objective
scope:
  domain_id: DOM-under-claw-work
  milestone_id: MLS-desktop-experience
title: Environment·Agent·Match·Memory를 Core 서비스 경유 관리 화면으로 제공한다
status: active
priority: normal
success_criteria:
  - Agent 등록·이름편집·활성/비활성·Environment 재바인딩이 AgentRegistryService만으로 이뤄진다.
  - Match 제안 목록·승인/거부/교정과 immutable audit history가 MatchService 경유로 표시된다.
  - Domain/Milestone/Task 스코프 Memory recall이 provenance·current/superseded로 표시되고 제한자료는 fail-closed다.
  - 세 화면 모두 공유 토큰/테마/StatusPill을 재사용하고 정본을 직접 편집하지 않는다.
knowledge_ids:
  - KNW-canonical-service-ui-boundary
reference_ids:
  - REF-desktop-gui-management-console
parent_objective_ids: []
created_at: 2026-07-24T00:00:00Z
updated_at: 2026-07-24T00:00:00Z
---

관리 콘솔이 Environment/Agent/Match/Memory 도메인을 모두 Worklog Core 서비스 경계 안에서 다루도록 하는 목표. UI는 canonical YAML을 직접 쓰지 않고, 식별자 불변성·audit·fail-closed 정책을 서비스 계층에 위임한다.

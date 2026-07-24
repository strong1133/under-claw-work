---
schema_version: 1
id: KNW-canonical-service-ui-boundary
type: knowledge
kind: constraint
scope:
  domain_ids:
    - DOM-under-claw-work
  milestone_ids:
    - MLS-desktop-experience
concepts:
  - architecture
  - canonical-store
  - ui-boundary
confidence: confirmed
origin:
  kind: user_authored
  actor_id: user:jsj
relations:
  supports: []
  contradicts: []
  supersedes: []
  derived_from: []
source_refs:
  - REF-desktop-gui-management-console
created_at: 2026-07-24T00:00:00Z
updated_at: 2026-07-24T00:00:00Z
---

관리 화면(Environment/Agent/Match/Memory)은 canonical YAML/Markdown을 직접 편집하지 않고 반드시 Core 서비스(EnvironmentService, AgentRegistryService, MatchService, MemoryRecallService)를 경유해야 한다. 이 경계 덕분에 식별자 불변성, 잠금 기반 원자적 쓰기, immutable audit Event, 제한자료 fail-closed 정책이 UI 회귀 없이 보장된다.

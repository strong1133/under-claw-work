---
schema_version: 1
id: KNW-d2coding-ligatures
type: knowledge
kind: constraint
scope:
  domain_ids:
    - DOM-under-claw-work
  milestone_ids:
    - MLS-desktop-experience
concepts:
  - typography
  - d2coding
  - monospace
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
  - REF-orca-warp-typography
created_at: 2026-07-24T00:00:00Z
updated_at: 2026-07-24T00:00:00Z
---

D2Coding은 한글/영문 고정폭 정렬이 우수한 코딩 폰트다. 라이선스(OFL) 범위에서 앱에 번들 가능하며, 코드/터미널 표면의 기본 모노스페이스로 사용한다. 폰트 자산은 pubspec에 등록하고 fontFamily 토큰으로 노출한다.

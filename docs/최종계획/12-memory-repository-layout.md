# 기억 저장소 레이아웃

<!-- 최종 계획 문서 -->

이 문서는 **사용자 기억 저장소의 폴더 구조에 대한 normative source**다.
엔티티별 필드 스키마는 [정본 데이터 모델](03-data-model.md), 설치 절차는
[설치·초기 설정·제거](10-installation-and-removal.md)를 따른다. 다른 문서의 트리
요약과 충돌하면 이 문서를 따른다.

제품 소스 저장소(`lib/`, `bin/`, `skills/`)의 구조와 혼동하지 않는다. 그것은
README의 `## 저장소 구조`가 다룬다.

## 소유 경계

Under Claw Work는 사용자가 설치 시 지정한 저장소 경로에 **레이아웃만** 보장한다.

| 항목 | 소유자 |
|---|---|
| 디렉터리 트리, placeholder, 레이아웃 매니페스트 | 도구 |
| Domain·Milestone·Task·Knowledge·Reference의 내용 | 사용자 |
| Persona·Skill Policy·host binding 구성 | 사용자 |
| 커밋·푸시·브랜치 전략 | 사용자 |

도구도 Agent도 요청받지 않은 Domain 생성, 기록 이관, 구조 변경을 수행하지 않는다.
`ensureLayout()`이 만드는 것은 빈 디렉터리와 placeholder, 매니페스트뿐이다.

## 표준 트리

```text
<사용자 지정 저장소 루트>/
├─ workdb/                     정본. Git이 추적한다.
│  ├─ workspace.yaml           레이아웃 매니페스트
│  ├─ tasks/{TSK-*}/           task.yaml, relations.yaml
│  ├─ domains/{DOM-*}/         domain.md
│  ├─ milestones/{MLS-*}/      milestone.md
│  ├─ projects/                PRJ-*.md
│  ├─ repositories/            REP-*.md
│  ├─ personas/                PER-*.md
│  ├─ agent-groups/            AGG-*.md
│  ├─ channel-bindings/        CHB-*.md
│  ├─ mcp-bindings/            MCB-*.md
│  ├─ skill-policies/          SKP-*.md
│  ├─ objectives/              OBJ-*.md
│  ├─ knowledge/               KNW-*.md
│  ├─ references/              REF-*.md
│  ├─ events/                  EVT-*.yaml (append-only)
│  ├─ claims/                  CLM-*.yaml
│  ├─ control-requests/        CTR-*.yaml (immutable)
│  ├─ control-dispositions/    EVT-*.yaml (immutable)
│  ├─ runs/                    RUN-*.yaml
│  ├─ invocations/             SKI-*.yaml
│  ├─ matches/                 MAT-*.yaml
│  ├─ config/                  environments.yaml, agents.yaml,
│  │                           skill-pipeline.yaml, repository-auth.yaml
│  ├─ task-candidates/         TGC-*.yaml
│  └─ schemas/                 정본 데이터 계약(제품이 배포)
└─ .worklog/                   호스트 로컬. Git이 추적하지 않는다.
   ├─ projection.sqlite3       재생성 가능한 SQLite projection
   ├─ obsidian/                파생 Obsidian vault
   ├─ migrations/              마이그레이션 리포트
   └─ setup.json               이 호스트의 워크스페이스 바인딩
```

## 규격화 방식

Git은 빈 디렉터리를 추적하지 않는다. 트리를 지정만 하면 clone한 다른 기기에는
디렉터리가 존재하지 않고, 사용자는 규격을 눈으로 확인할 수도 없다. 따라서 두 가지를
함께 둔다.

1. **placeholder** — 각 정본 디렉터리에 `.gitkeep`을 씨딩한다. 커밋하면 트리 전체가
   그대로 clone된다. `.gitkeep`은 정본 파일명 필터를 통과하지 못하므로 엔티티로
   디코딩되지 않는다.
2. **레이아웃 매니페스트** — `workdb/workspace.yaml`에 `layout_version`과 정본·
   호스트로컬 디렉터리 목록을 기록한다. "초기화된 적 없음"과 "구버전으로 초기화됨"을
   구별하는 근거다.

호스트 로컬 디렉터리는 placeholder를 두지 않는다. 커밋 대상이 아니고 언제든
재생성되기 때문이다.

## 레이아웃 버전

`layout_version`은 표준 디렉터리 집합이 바뀔 때만 올린다. 엔티티 스키마 변경은
각 문서의 `schema_version`이 담당하며 이 값과 무관하다.

| 값 | 의미 |
|---|---|
| 매니페스트 없음 | 이 기능 이전에 만들어진 저장소. 실패가 아니며 다음 `init`이 채운다. |
| 현재 값보다 낮음 | 구버전 빌드가 초기화했다. `init`으로 승격한다. |
| 현재 값보다 높음 | 최신 빌드가 초기화한 저장소를 구버전 빌드로 열었다. 쓰기 전에 업데이트한다. |

## 진단

```bash
worklog doctor <workspace>
```

| `workspace=` | 의미 |
|---|---|
| `ok` | 트리·placeholder·버전이 모두 현재 규격 |
| `unversioned` | 트리는 있으나 매니페스트가 없다 |
| `version_mismatch` | 매니페스트 버전이 이 빌드와 다르다 |
| `incomplete` | 정본 디렉터리가 없다. `missing_directory=`로 이름을 출력한다 |
| `not_portable` | 디렉터리는 있으나 placeholder가 없어 clone되지 않는다. `unportable_directory=`로 출력한다 |

`doctor`는 진단만 하고 고치지 않는다. 사용자가 자기 저장소의 상태를 먼저 보고
복구를 결정하도록 하기 위해서다. 복구는 `worklog init <workspace>`다.

## 커밋 경계

- `workdb/` 전체를 커밋한다.
- `.worklog/`는 커밋하지 않는다. `init`이 저장소 `.gitignore`에 `.worklog/`를 보장한다.
- SQLite projection, 파생 vault, 마이그레이션 리포트는 언제든 버리고 다시 만들 수 있다.
- 실제 password, verifier, token, credential은 어느 경로에도 저장하지 않는다.
  `workdb/config/repository-auth.yaml`은 공개 가능한 policy와 opaque locator만 담는다.
- 환경별 절대경로를 정본 엔티티에 저장하지 않는다. 로컬 경로 바인딩은 호스트 로컬
  설정의 몫이다.

## 여러 저장소

한 설치에서 여러 기억 저장소를 연결할 수 있다. clone, SQLite, auth session은
저장소별로 격리하며, 각 저장소가 자기 `workspace.yaml`과 `.worklog/`를 가진다.

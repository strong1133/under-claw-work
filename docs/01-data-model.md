# task prompt 데이터 모델

DDL: [`schema/001_init.sql`](../schema/001_init.sql)

## 무엇을 푸는 문서인가

프롬프트 초안을 날짜별 Markdown 파일에 `====` 구분자로 raw하게 쌓던 방식을 대체한다.
그 방식에서 실제로 발생한 문제는 다음과 같다.

| 문제 | 이 모델에서의 해소 |
|---|---|
| 원하는 초안을 하나하나 찾아야 함 | `task` 행 1건 = 초안 1건. id로 직접 조회 |
| 내용이 길면 스크롤이 끝없이 길어짐 | 레코드 단위 조회. 목록은 `title`만 표시 |
| 상태 관리를 사람이 직접 함 | `task.status` / `task.stage` |
| 도메인·마일스톤별로 묶어 볼 수 없음 | `domain` / `milestone` 외래키 + GROUP BY |
| 대기중 초안을 복사해 AI에 붙여넣어야 함 | `task_queue` 뷰에서 에이전트가 직접 조회 |
| 결과 추적이 안 됨 | `task_run` |
| AI가 task 이력을 확인할 수 없음 | 전 이력이 질의 가능한 관계형 데이터 |

## 계층

```
domain                      주요 목표 · 공통사항 · 제약사항
  └─ milestone              주요 목표 · 공통사항 · 제약사항
       └─ task              초안 · 메타 프롬프트 · 상태 · 단계
            ├─ parent_id    상하위 구조 (자기참조, 재귀 조회)
            ├─ task_link    관련 task (다대다)
            ├─ task_model   작업할 모델 (다대다)
            ├─ task_target  작업대상 프로젝트
            └─ task_run     실행 이력

reference                   도메인 · 마일스톤 · task 전부와 다대다
```

- `task`는 도메인에 **속할 수도, 속하지 않을 수도** 있다 (`domain_id` nullable).
- 마일스톤은 반드시 도메인에 속한다. `task`가 마일스톤을 가지면 도메인도 반드시 가진다 —
  복합 외래키 `(milestone_id, domain_id)`로 DB가 강제한다. 마일스톤만 있고 도메인이 없는
  상태는 만들 수 없다.

## 상태를 두 축으로 나눈 이유

한 축으로 합치면 "완료됐지만 검수 대기"와 "막혔지만 실행 단계"를 표현할 수 없다.

| 축 | 컬럼 | 값 | 의미 |
|---|---|---|---|
| 관리 상태 | `task.status` | `open` `blocked` `done` `dropped` | 이 task가 살아있는가 |
| 처리 단계 | `task.stage` | `draft` `meta` `ready` `running` `review` | 파이프라인 어디에 있는가 |

정상 흐름은 `draft → meta → ready → running → review` 이고, 종료 시 `status`를 `done`으로 바꾼다.
`blocked`는 단계를 유지한 채 관리 상태만 바뀐다.

**실행 대기 큐**는 `status='open' AND stage='ready'` 로 정의되며 `task_queue` 뷰로 제공한다.
복사·붙여넣기가 사라지는 지점이 여기다. 에이전트는 이 뷰를 조회해 `meta_prompt`를 가져간다.

## 테이블별 목적

### domain / milestone

둘 다 동일한 3개 서술 필드를 가진다.

| 컬럼 | 의미 |
|---|---|
| `objectives` | 주요 목표 |
| `common_notes` | 소속 task 전반에 공통 적용되는 사항 |
| `constraint_notes` | 소속 task가 지켜야 하는 제약 |

자동 처리(`task.auto = true`) 시 에이전트가 따라야 할 원칙의 출처가 이 필드들이다.

> `constraints`는 SQL 예약어와 충돌하므로 컬럼명을 `constraint_notes`로 둔다.

### task

| 컬럼 | 의미 |
|---|---|
| `id` | 발급과 동시에 확정되는 고유 id. 형식은 [`02-database-setup.md`](02-database-setup.md#id-규칙) |
| `title` | 목록 조회용 요약 제목 |
| `draft` | 프롬프트 초안 원문 |
| `meta_prompt` | 초안으로부터 생성된 메타 프롬프팅 결과 |
| `status` / `stage` | 위 두 축 |
| `auto` | 자동화 대상 여부 |
| `environment_id` | 처리할 환경 (`mac`, `astro-hermes` 등). 단일 |
| `parent_id` | 상위 task |

`draft`와 `meta_prompt`는 길이 제한이 없다 — 실측상 초안 본문은 최대 6,797자였고
메타 프롬프트는 그보다 길다.

### environment / model

`environment`는 task당 하나, `model`은 `task_model`을 통해 **여러 개** 연결된다.
모델별 역할이 다를 수 있어 `role` 컬럼(`primary` / `review` / `fallback`)을 둔다.

### reference

참고자료는 세 계층 전부와 연결된다. 링크 테이블을 계층별로 분리한 이유는
다형 참조(`entity_type` + `entity_id`)로 만들면 외래키 무결성을 잃기 때문이다.
DB를 택한 이유 중 하나가 무결성이므로, 테이블 3개를 쓰는 쪽이 일관된다.

- `domain_reference`
- `milestone_reference`
- `task_reference`

`kind`가 `knowledge`/`snippet`이면 `body`에 내용을 직접 보유하고,
`file`/`url`이면 `uri`가 위치를 가리킨다. 둘 다 비어 있을 수 없다(CHECK 제약).

### task_run

한 task는 여러 번 실행될 수 있다. 실행 1회 = 행 1건.
어떤 환경에서 어떤 모델로 언제 돌렸고 결과가 무엇이었는지 남긴다.

## 필드의 출처

설계 근거를 추적 가능하게 남긴다. 관측 수치는 기존 work-log의 실제 초안 92건 기준이다.

| 필드 | 출처 |
|---|---|
| `draft` | 관측 — 92/92 사용 |
| `meta_prompt` | 관측 — 17/92 (18%) 작성됨 |
| `task_target` | 관측 — `targets::` 63/92 (68%) |
| `task_link` | 관측 — `related::` 10/92 (11%) |
| `domain` | 관측 — 폴더 구조에 5개 도메인 |
| `id` 형식 | 관측 — 기존 `PT-YYYYMMDD-{약어}-NN` 규칙 계승 |
| `status` / `stage` | 요구 — 기존에 실제 쓰인 상태값은 2종뿐이었고, 단계 구분은 요구사항 기반 |
| `task_run` | 요구 — "결과 추적이 안 됨" |
| `milestone` | 요구 |
| `parent_id` | 요구 |
| `auto` | 요구 |
| `environment` / `model` | 요구 |
| `reference` | 요구 |
| `title` | 신규 — 기존 블록에는 제목 필드가 없었다. 목록 조회를 위해 추가 |

## 이번 범위에 넣지 않은 것

- **초안 개정 이력.** `UPDATE` 하면 이전 초안은 사라진다. 필요해지면
  `task_revision(task_id, revision, draft, meta_prompt, at)` 한 테이블로 추가한다.
- **기존 92건 마이그레이션.** 구조 확정 후 별도로 진행한다.
- **todo 체계와의 연결.**
- **AI 기반 자동 처리 실행.** `auto` 플래그와 도메인/마일스톤 원칙 필드까지만 준비하고,
  실제 자동 생성·실행 로직은 다루지 않는다.

## 조회 예시

```sql
-- 도메인별 미완료 현황
SELECT domain_id, stage, count(*)
  FROM task
 WHERE status = 'open'
 GROUP BY domain_id, stage
 ORDER BY domain_id, stage;

-- 실행 대기 큐
SELECT * FROM task_queue;

-- 특정 task의 하위 트리 전체
WITH RECURSIVE tree AS (
  SELECT id, title, parent_id, 0 AS depth
    FROM task WHERE id = 'PT-20260722-ffg-03'
  UNION ALL
  SELECT t.id, t.title, t.parent_id, tree.depth + 1
    FROM task t JOIN tree ON t.parent_id = tree.id
)
SELECT repeat('  ', depth) || title AS outline, id FROM tree;

-- task가 참조해야 할 원칙 + 참고자료 일괄 조회
SELECT d.objectives, d.constraint_notes, m.objectives, m.constraint_notes,
       r.title, r.kind, r.uri
  FROM task t
  LEFT JOIN domain    d ON d.id = t.domain_id
  LEFT JOIN milestone m ON m.id = t.milestone_id
  LEFT JOIN task_reference tr ON tr.task_id = t.id
  LEFT JOIN reference r ON r.id = tr.reference_id
 WHERE t.id = 'PT-20260722-ffg-03';
```

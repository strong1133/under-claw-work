# 전체 계획 회차 3 설계 doc (2026-07-23)

## 1. 요구 & 성공기준

최초 요구는 `docs/최종계획/00-최종계획.md`와 연결 문서 전체를 구현하는 것이다. 현재 구현은 정본 CRUD, Task Prompt 승인, ControlRequest, SQLite 재생성과 기본 GUI를 제공하지만 critic이 지적한 타입 관계 계약과 실행용 context pack의 결정성·예산·출처·대체·상충 처리가 빠져 있다.

- 관계 이름, source/target kind와 cardinality가 registry로 검증된다. `[verify: 허용/금지/단일 cardinality/누락 target 테스트]`
- context pack은 같은 정본에서 항상 같은 순서와 선택 결과를 만들고 token budget을 지킨다. `[verify: 순서·budget 반복 동등성 테스트]`
- 각 context 항목은 provenance와 선택 이유를 보존한다. `[verify: direct/scope/graph provenance assertion]`
- superseded Knowledge는 제외되고 contradiction은 실행자가 알 수 있게 표시된다. `[verify: supersedes/contradicts graph fixture]`
- 기존 단순 `EntityService.buildContext` API와 테스트는 깨지지 않는다. `[verify: 전체 test suite]`

Brownfield 대조:

| 계획 의도 | 현재 구현 | 회차 3 교정 |
|---|---|---|
| 타입 관계·cardinality | 임의 field link와 ID 존재만 검사 | registry 기반 source/target/cardinality 검증 |
| budgeted context graph | scope 일치 항목 전부 반환 | 직접 링크→scope→graph 확장, 안정 정렬·예산 |
| provenance/supersession/contradiction | 없음 | 항목별 근거와 graph 상태 기록 |
| 범용 2020-12 schema | 일부 YAML과 수동 validator | 자체 범용 엔진을 발명하지 않고 별도 후속 범위로 유지 |

## 2. 채택 접근법 & 근거

정본 파일 구조와 기존 repository API는 유지하고 두 개의 순수 Core 서비스를 추가한다. `RelationRegistry`는 계획에 명시된 관계만 타입 계약으로 제공하고, `ContextPackBuilder`는 task 관계와 scope를 합쳐 후보 graph를 만든 뒤 결정적 점수와 예산으로 선택한다.

버린 대안은 자체 JSON Schema 2020-12 validator 구현이다. 현재 dependency에 표준 validator가 없으며 부분 구현을 완전 호환처럼 보이게 하는 것은 정확성 요구에 반한다.

## 3. 변경 범위 & 파일

- `lib/core/relation_registry.dart`: 관계 계약과 relations.yaml 검증
- `lib/core/context_builder.dart`: 결정적 context pack
- `lib/core/entity_service.dart`, `lib/core/worklog_core.dart`: 호환 API 연결·export
- `test/context_relation_test.dart`: valid/invalid graph 및 context E2E

Flutter 화면, 인증, installer, 기존 control 흐름은 건드리지 않는다.

## 4. 프로젝트 간 계약 영향

공개 Dart Core에 `RelationRegistry`, `ContextPackBuilder`, `ExecutionContextPack`, `ContextEntry`가 추가된다. 기존 `ContextPack`과 CLI 출력 형식은 유지한다.

## 5. 리스크 & 미해결 가정

- token 수는 model tokenizer가 아니라 보수적인 `문자/4` 추정이다. 정확한 tokenizer는 provider-neutral 계약상 runner adapter가 선택적으로 제공해야 한다.
- schema 전체와 원격 CAS/auth/signing은 이 변경으로 완료되지 않는다. 완료로 주장하지 않고 독립 후속 acceptance로 남긴다.
- registry에 없는 관계는 즉시 거부한다. 확장은 registry 변경과 테스트를 동반해야 한다.

## 6. 검증 방법

관계 fixture 단위 테스트, context graph E2E, 기존 전체 Flutter test, format/analyze, CLI/macOS build, secret scan과 diff check를 실행한다.

## 7. task 분할

1. 관계 계약 registry를 구현한다. 검증: valid/invalid/cardinality test.
2. deterministic budgeted context builder를 구현한다. 검증: provenance/supersession/contradiction/budget test.
3. 기존 API와 CLI 호환 연결을 한다. 검증: 기존 entity test와 전체 suite.
4. 저장소 표준 검증을 수행하고 미검증 외부 조건을 명시한다.

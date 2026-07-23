# 세 스킬 오케스트레이션

<!-- 최종 계획 문서 -->

## 기본 bundle

모든 설치 artifact는 다음 세 스킬을 version pin과 checksum이 있는 하나의 bundle로 포함한다.

1. `under-claw-meta-prompt`
2. `under-claw-jarvis-plan`
3. `under-claw-jarvis-plan-loop`

host별 실제 진입점, 설치 가능 범위, 충돌과 제거 소유권은 [설치·초기 설정·제거](10-installation-and-removal.md)의 확인된 upstream 대응표와 acceptance를 따른다. 특히 Hermes는 별도 adapter 검증 전 설치 지원으로 간주하지 않는다.

## 모든 Task의 필수 pipeline

```text
Draft 생성/수정
→ under-claw-meta-prompt 명시적 호출
→ Meta 검토·승인
→ under-claw-jarvis-plan-loop 명시적 호출
→ 각 loop round에서 under-claw-jarvis-plan 명시적 호출
→ 분리 reviewer verdict
→ 완료/차단/실패
```

이 순서로 세 스킬이 모두 실제 활용된다.

- `under-claw-meta-prompt`: 실행하지 않고 Draft를 독립 실행용 Meta Prompt로 변환
- `under-claw-jarvis-plan-loop`: 전체 실행의 회차, fresh implementer, 분리 reviewer와 score gate 담당
- `under-claw-jarvis-plan`: 각 회차의 이해→계획→구현→검수 담당

loop가 base plan을 호출하므로 Core는 base plan을 별도로 중복 선행 실행하지 않는다. 자동 생성 Task도 예외 없이 같은 pipeline을 거친다.

## 공급자 중립 계약

```text
RunnerAdapter
  discover_capabilities()
  install_skill_bundle(bundle_ref)
  invoke_skill(skill_id, input_ref, run_id)
  control_run(run_id, pause|resume|cancel)
  stream_events(run_id, cursor)
  collect_result(run_id)
```

Task에는 특정 model ID를 필수값으로 저장하지 않는다. Environment/Agent registry가 실행 시점에 capability가 맞는 runner를 선택한다. native skill invocation이 없으면 generic adapter가 동일 bundle 문서와 입력을 격리된 실행 context에 전달한다.

## 실행 증거와 실패 정책

각 invocation은 `SKI-` ID, skill ID, bundle version, input revision, Agent/Environment, 시작·종료 시각, 결과 ref를 Event로 남긴다.

- 필수 스킬 없음·checksum 불일치: 실행 차단, repair 안내
- Meta stale: Meta 재생성 전 실행 차단
- loop reviewer 미통과: Task 완료 금지
- runner pause 미지원: 요청 reject, 실행 상태 유지
- provider 장애: Run을 `blocked` 또는 `failed`로 기록하고 다른 provider 자동 전환은 명시적 policy가 있을 때만 허용

## 설치·업데이트·제거

설치·업데이트·제거의 normative source는 [설치·초기 설정·제거](10-installation-and-removal.md)다.

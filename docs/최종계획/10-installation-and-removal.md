# 설치·초기 설정·제거

<!-- 최종 계획 문서 -->

이 문서는 Worklog 설치, 업데이트, ownership과 제거의 **normative source**다. 인증 세부 계약은 [로그인과 보안](06-security-auth.md)을 따른다. 다른 문서의 설치 요약과 충돌하면 이 문서를 따른다.

## 설치 진입점

- macOS: 서명·notarization된 `.dmg`/`.pkg`
- Windows: 서명된 `.exe`/`.msi`
- Linux desktop: AppImage, 필요 시 `.deb`
- headless/Hermes: 단일 `worklog` bootstrap 바이너리

사용자는 Git, SQLite, Flutter, Go와 under-claw 스킬을 별도 설치하지 않는다.

## 최초 setup

Desktop wizard와 `worklog setup`은 같은 Core 흐름을 사용한다.

1. 설치 artifact 서명/checksum 검증
2. application data 경로와 install manifest 생성
3. Agent host 감지
4. acceptance를 통과한 감지 host에 세 under-claw skill bundle과 adapter 설치; 미검증 host는 건너뛰고 보고
5. GitHub 인증
6. target Private Git repository 선택
7. repository auth policy 확인
8. policy가 없으면 [로그인과 보안](06-security-auth.md)의 선정 gate를 통과한 provider로 repository password 등록
9. policy가 있으면 선정된 표준 인증 protocol로 repository password 인증
10. clone, Environment 등록, SQLite 자동 생성, 진단 실행

password는 GUI secure field 또는 TTY hidden input으로만 받는다. CLI flag, 환경변수, 설정파일과 로그로 받지 않는다.

## 재실행·추가 환경

같은 기기는 OS secure store의 repository locator와 policy cache를 사용해 password 잠금 화면부터 시작한다. 새 기기는 Private repository 접근을 위해 GitHub 인증과 repository 선택을 먼저 한 뒤 password를 입력한다.

한 설치에서 여러 repository를 연결할 수 있으며 clone, SQLite, auth session은 repository별로 격리한다.

## 확인된 upstream 설치 방식

읽기 전용으로 확인한 upstream `install.sh`, `tests/install.sh`, `skills/.../references/05-host-map.md` 기준이다.

| Host | 현재 upstream 전역 대상 | 진입점 | 현재 update/충돌 동작 | Worklog 설치기 요구 |
|---|---|---|---|---|
| Claude Code | `~/.claude/commands/{skill}.md`, `~/.claude/skills/{skill}/` | `/skill-name`, command + `SKILL.md` | 기존 대상 백업 후 전체 교체 | 기존 소유자 검사, adopt 승인, 원본 backup ref를 manifest에 기록 |
| Codex | `${CODEX_HOME:-~/.codex}/skills/{skill}/` | `$skill-name`, `SKILL.md` | 기존 tree 백업 후 전체 교체 | `CODEX_HOME` 해석 결과와 설치 checksum 기록 |
| Gemini CLI | `${GEMINI_HOME:-~/.gemini}/skills/{skill}/` | `GEMINI.md` | 명시 옵션 설치, 기존 tree 백업 후 전체 교체 | opt-in host 활성화와 진입점 검증 |
| 프로젝트 skill-map | `<repo>/docs/under-claw-jarvis-plan/skill-map.md` | 단계별 매핑 | upstream 설치 대상이 아니며 update에서 보존 | 사용자 소유 파일로 분류해 제거 금지 |
| Hermes | upstream에 설치 경로·진입점 없음 | 미확정 | 지원 확인 불가 | 별도 adapter spike와 acceptance 전 자동 쓰기 금지 |
| generic | upstream 설치 대상 없음 | `SKILL.md`/reference fallback | 지원 확인 불가 | 격리 runtime에서 C1/C2/C3 fallback contract 검증 |

확인된 upstream은 staging, timestamped backup과 실패 rollback을 제공하지만 영속 install manifest와 uninstall 명령은 제공하지 않는다. Worklog 설치기가 이를 추가해야 하며 upstream 설치가 곧 안전한 제거 소유권을 뜻한다고 가정하지 않는다.

### Host adapter acceptance

- 세 스킬 진입점과 모든 필수 reference가 설치 후 checksum과 일치
- native 호출 또는 C1/C2/C3 fallback self-test 통과
- 기존 동명 대상이 다른 소유자면 자동 덮어쓰지 않고 충돌 보고
- 명시적 adopt 시 원본 backup과 복원 위치를 manifest에 기록
- 재설치는 Worklog 소유 파일만 atomic staging으로 갱신
- 제거는 Worklog 소유 파일 삭제 또는 adopt 이전 원본 복원
- project skill-map과 사용자 생성 파일 보존
- Hermes 등 미확인 host는 adapter별 install path, invoke, update, uninstall contract test 전 지원 표시 금지

## 업데이트

서명된 manifest와 artifact checksum을 검증한 뒤 staging 설치한다. Core, GUI, skill bundle, adapter version을 함께 호환성 검사하고 실패 시 이전 install manifest로 rollback한다. repository 데이터와 사용자 skill-map은 업데이트 대상이 아니다.

## 제거 모드

```text
앱만 제거
  GUI/CLI launcher와 installer 소유 host adapter 제거
  repository clone·cache·credential 유지

앱+runtime 제거
  위 항목 + Core·skill bundle·cache 제거
  repository clone과 credential 유지

완전 제거
  위 항목 + local clone·repository별 credential·Environment 등록 제거
```

완전 제거 전에 정확한 절대경로와 삭제 항목을 보여주고 확인받는다. uninstaller는 install manifest에 없는 파일, 원격 Git repository와 원격 auth policy를 삭제하지 않는다. 원격 Environment revoke나 repository auth 제거는 별도 명시적 관리 작업이다.

upstream timestamped backup은 Worklog ownership manifest를 대신하지 않는다. Worklog가 기존 설치를 adopt했다면 제거 시 manifest가 가리키는 검증된 원본만 복원하고, backup이 없거나 checksum이 달라졌으면 자동 삭제·복원하지 않고 충돌로 중단한다.

## 설치/제거 완료 기준

- clean machine에서 단일 artifact만으로 setup 완료
- SQLite와 skill bundle 자동 준비
- 동일 repository를 다른 OS에서 password로 잠금 해제
- 재설치 시 사용자 설정 보존
- 완전 제거 후 installer 소유 파일·credential만 제거
- 설치·제거 로그에 password, verifier와 token이 없음

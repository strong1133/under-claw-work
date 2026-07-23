# 로그인과 보안

<!-- 최종 계획 문서 -->

이 문서는 repository password, provider 선정, challenge 검증, cross-device와 실패 복구의 **normative source**다. 다른 문서의 요약과 충돌하면 이 문서를 따른다.

## 로그인 요구사항

- 사용자명 없이 패스워드 한 개만 입력한다.
- 설치파일에는 평문 패스워드를 포함하지 않는다.
- 저장소, 문서, 소스, 빌드 로그와 앱 로그에 실제 패스워드를 기록하지 않는다.
- 패스워드는 전역 공용값이 아니라 target Git repository별로 최초 setup에서 설정한다.
- Git 정본에는 평문 password와 실제 verifier payload를 저장하지 않는다.

## 최초 repository password 설정

설치 artifact에는 초기 password나 verifier가 없다. repository의 auth policy가 없는 최초 setup에서 repository write 권한을 가진 사용자가 새 password와 확인값을 입력한다.

```text
GitHub 인증
→ target repository 선택
→ auth policy 없음과 bootstrap lock 확인
→ 새 password 2회 입력
→ 선정 gate를 통과한 AuthProvider에 repository auth 등록
→ 공개 policy ID와 locator만 Git 정본에 commit
→ 현재 기기의 OS secure store에 policy cache 저장
```

동시에 두 환경이 최초 설정을 시도하면 repository bootstrap lock과 조건부 commit으로 하나만 성공해야 한다.

금지:

- 소스 상수에 평문 입력
- 빌드 시 전역 공용 password 또는 verifier 주입
- Git 정본에 실제 verifier payload commit
- GitHub Actions workflow YAML에 실제 값 입력
- `.env` 또는 credentials 파일 commit
- 패스워드와 hash를 앱 로그에 출력
- 단순 SHA-256 단독 사용

## AuthProvider 선정 gate

`workdb/config/repository-auth.yaml`에는 다음 공개 메타데이터만 저장한다.

```text
auth policy ID
policy version
verifier provider kind
opaque locator
KDF algorithm과 parameter profile
```

provider는 현재 미선정이다. 특정 GitHub 기능이나 저장 위치를 구현으로 확정하지 않는다. 구현 전에 후보별 spike를 수행하고 다음 acceptance를 모두 통과한 하나만 `provider_selection_status: accepted`로 변경한다.

| 검증축 | 필수 acceptance |
|---|---|
| API | enroll, authenticate, rotate, revoke, health 동작과 오류 코드가 표준 protocol contract/conformance test를 통과 |
| 권한 | repository별 최소 read/write/admin 권한이 분리되고 권한 없는 repository 접근이 거부됨 |
| 기밀성 | server-side verifier가 클라이언트·Git·로그·crash dump·artifact로 반환되지 않음 |
| Cross-device | 두 운영체제의 새 기기가 같은 repository와 password로 각각 독립 인증 |
| 실패 복구 | provider timeout, partial bootstrap, password rotate 중단, policy version 불일치를 재시도하거나 rollback |
| 감사 | bootstrap, 성공/실패 인증, rotate, revoke에 비밀값 없는 audit ID와 시각 기록 |
| Offline guessing 저항 | 캡처한 transcript와 저장 데이터만으로 password 후보를 오프라인 검증할 수 없음 |
| Replay | 이전 인증 transcript, message와 grant 재사용이 거부됨 |
| MITM/channel binding | active MITM 방어와 표준 channel binding을 제공하며 binding 누락·downgrade를 거부 |
| Repository binding | 인증 결과가 canonical repository ID에 묶여 다른 repository로 credential/proof forwarding 불가 |
| Rate limit | provider가 repository·환경·network 단위 rate limit, backoff와 abuse audit을 강제 |
| 구현 신뢰 | 검토된 표준 구현과 test vector를 사용하고 자체 cryptographic construction을 포함하지 않음 |

미달 후보는 채택하지 않는다. 공개 repository content에 verifier를 저장하거나 verifier를 내려받아 클라이언트에서 비교하는 구현은 권장 계약이 아니며 별도 threat-model 승인 없이는 금지한다.

## 허용 인증 프로토콜 후보

후보는 다음 두 종류로 제한한다.

- 검토된 PAKE 프로토콜(예: OPAQUE)의 유지보수되는 구현
- 위 acceptance를 만족하는 표준 외부 인증 프로토콜과 provider

임의의 `password + nonce → proof`, 독자 challenge/response, 자체 KDF 조합 또는 자체 암호 프로토콜 설계는 금지한다. 특정 프로토콜의 최종 선정은 구현 spike와 acceptance gate 이후에만 한다.

선정 구현은 password나 재사용 가능한 verifier를 네트워크로 반환하지 않고, 표준 프로토콜이 제공하는 transcript 검증·replay 방어·서버 인증·channel binding을 그대로 사용해야 한다. 인증 결과는 canonical repository ID, policy version과 Environment에 묶인 short-lived grant여야 한다.

- bootstrap과 rotate는 조건부 policy version 교체를 사용한다.
- provider API가 비가용이면 새 기기 인증은 fail closed한다. 기존 기기의 offline unlock은 별도 명시 정책과 OS secure-store device credential이 있을 때만 허용한다.

## 로그인 처리

새 기기의 최초 연결:

1. GitHub 인증
2. target repository 선택
3. repository auth policy와 선정된 표준 인증 protocol 시작
4. password 잠금 화면 표시
5. 검증 성공 후 clone과 인덱싱

이미 연결된 기기:

1. 앱 시작 시 target repository가 표시된 잠금 화면
2. 입력을 메모리에서만 보유
3. 온라인 표준 인증 protocol 또는 명시적으로 등록된 device offline credential로 검증
4. 성공 시 메모리 session 생성
5. 입력 buffer 즉시 제거
6. 실패 횟수에 따라 지연 증가
7. 앱 종료 또는 잠금 시 session 폐기

온라인이 되면 policy version을 확인한다. password 변경으로 device policy가 오래됐으면 session을 잠그고 선정된 표준 protocol로 재인증한다.

권장 기본값:

- 5회 실패 후 30초 지연
- 이후 지수 backoff
- 오류 메시지는 “로그인에 실패했습니다”로 통일
- clipboard 자동 복사 금지
- 기본적으로 패스워드 표시 버튼 비활성
- 일정 시간 비활동 시 자동 잠금 설정 제공

KDF parameter는 provider spike에서 지원 플랫폼의 성능과 보안 기준을 검증해 versioned policy로 정한다.

## 중요한 보안 경계

repository password 로그인은 Worklog Studio GUI와 Core 사용을 잠그는 공유 접근 제어다. 이것만으로 다음을 보호하지는 못한다.

- OS 관리자 권한으로 로컬 파일을 직접 읽는 공격
- 이미 clone된 Git working copy
- 탈취된 GitHub credential
- 디스크를 분리하여 읽는 공격

따라서 실제 데이터 보호는 다음 계층이 함께 담당한다.

1. GitHub Private 저장소 권한
2. GitHub credential의 OS secure store 보관
3. macOS FileVault, Windows BitLocker, Linux disk encryption
4. OS 사용자 계정 잠금
5. 저장소 push 전 민감정보 검사

첫 버전에서 Git 정본 전체를 앱 패스워드로 암호화하지 않는다. 그렇게 하면 headless Agent, Git diff, merge와 검색이 크게 복잡해진다. 정본 암호화가 필요하면 별도 위협 모델과 key recovery 설계를 거쳐야 한다.

## GitHub 인증

최초 연결에서만 GitHub OAuth Device Flow 또는 시스템 브라우저 기반 OAuth를 사용한다.

- 앱 로그인 패스워드와 GitHub 인증은 별개다.
- 최소 저장소 권한만 요청한다.
- token은 OS secure store에 저장한다.
- token을 `settings.json`, Git remote URL과 로그에 넣지 않는다.

OS 저장소:

- macOS Keychain
- Windows Credential Manager
- Linux Secret Service/libsecret

GUI 없는 환경은 환경별 fine-grained token 또는 GitHub App installation token을 사용하고 secret store에서 주입한다.

## 환경 등록과 revoke

각 설치는 Environment ID를 발급한다. 환경을 분실하거나 폐기하면 GUI에서 비활성화하고 GitHub credential을 revoke할 수 있어야 한다.

환경 registry에는 공개 가능한 메타데이터만 저장한다.

```text
ID, 이름, OS, architecture, capability, 상태, 마지막 접속 시각
```

기기 fingerprint, token, 패스워드 verifier와 개인 키는 저장하지 않는다.

## 로그

로그 허용:

- Event ID
- Task ID
- 상태 코드
- 수행 시간
- 마스킹된 경로

로그 금지:

- 패스워드 입력과 verifier
- GitHub token
- authorization header
- 환경변수 전체 dump
- Prompt와 Knowledge 전문
- 고객사명, 실명, 연락처와 사용자 데이터
- 내부 서버 주소

구조화 로깅에 중앙 redaction layer를 적용하고 오류 stack에도 동일 필터를 적용한다.

## 저장소 보안 검사

모든 commit/push 경로에서 저장소 `AGENTS.md`의 검사 정책을 적용한다.

- DB 접속정보
- 인증정보
- 서버 IP와 내부 도메인
- 내부 레포 URL
- 고객사·조직명
- 사용자 식별정보
- 디자인 도구 내부 링크
- 환경·credential 파일

검출 시 push를 차단하고 사용자가 검토하도록 한다. 자동 마스킹은 원문 손실 위험이 있으므로 diff 확인 후 적용한다.

## 배포 보안

- macOS code signing 및 notarization
- Windows Authenticode 서명
- Linux checksum과 가능하면 package signature
- release artifact SHA-256 checksum 제공
- update manifest 서명 검증
- 이전 버전 downgrade 공격 방지
- CI 로그에 secret이 나타나지 않는 테스트

## 패스워드 변경

초기 버전에도 관리자 패스워드 변경 기능을 포함한다.

1. 현재 패스워드 확인
2. 새 패스워드와 확인 입력
3. 새 verifier 생성
4. 선정된 AuthProvider에서 조건부 교체
5. repository auth policy version 증가
6. 다른 환경의 기존 session 폐기와 재인증

password 변경은 repository auth policy version과 server-side verifier를 조건부로 교체한다. 연결된 환경은 다음 policy 확인에서 기존 session을 폐기하고 새 password를 요구한다.

공유 password 방식은 사용자별 권한·감사·폐기 기능을 제공하지 않는다. 첫 버전은 단일 저장소 소유자 용도로 제한하며, 다사용자 요구가 생기면 사용자별 identity와 credential을 별도 설계한다.

# 데이터 저장소 구축 절차

AI 에이전트가 이 문서만 보고 대상 환경에 데이터 저장소를 스스로 세울 수 있도록 절차를 정의한다.

- 컨테이너 정의: [`docker/compose.yaml`](../docker/compose.yaml)
- 구축 스크립트: [`docker/setup.sh`](../docker/setup.sh)
- 스키마: [`schema/001_init.sql`](../schema/001_init.sql)

## 대전제

- **이 레포지토리는 데이터를 저장하지 않는다.** 업무지침·워크플로 명세·스킬만 담는다.
- **접속정보를 어떤 형태로도 커밋하지 않는다.** 비밀번호·연결 문자열·인증서 전부 해당한다.
- 데이터는 컨테이너 밖 호스트 디렉터리에 **볼륨 마운트**로 영속화한다. 컨테이너를 지워도 남는다.

## 한 줄 구축

```sh
./docker/setup.sh
```

이 스크립트가 하는 일은 다음과 같다. **몇 번을 실행해도 안전하다** — 이미 있는 접속정보와 데이터는 건드리지 않는다.

1. docker / docker compose v2 / 데몬 가동 여부 확인
2. 접속정보가 없으면 생성 (있으면 그대로 사용)
3. 데이터 디렉터리 생성
4. PostgreSQL 16 컨테이너 기동
5. 스키마 적용 확인 — 최초 기동 시 자동 적용되며, 아니면 수동 적용
6. 검증 후 결과 출력. 테이블이 13개가 아니면 실패로 종료

전제 조건은 `docker`, `docker compose` v2, `openssl` 셋뿐이다. 호스트에 PostgreSQL을 설치하지 않는다.

## 구성 요소

| 항목 | 값 |
|---|---|
| 이미지 | `postgres:16-alpine` |
| 컨테이너 | `under-claw-db` |
| 데이터베이스 | `under_claw_work` |
| 사용자 | `under_claw` |
| 바인딩 | `127.0.0.1:5432` — **루프백 전용** |
| 데이터 | `~/.local/share/under-claw-work/pgdata` |
| 접속정보 | `~/.config/under-claw-work/db.env` (권한 600) |
| 재시작 정책 | `unless-stopped` — 호스트 재부팅 후 자동 기동 |

## 접속정보 규약

접속정보는 레포 밖, 사용자 홈에 둔다.

```
~/.config/under-claw-work/db.env      # 파일 600, 디렉터리 700
```

```sh
POSTGRES_DB=under_claw_work
POSTGRES_USER=under_claw
POSTGRES_PASSWORD=<openssl rand -hex 24 로 생성>
POSTGRES_PORT=5432
POSTGRES_BIND=127.0.0.1
UNDER_CLAW_DATA_DIR=<홈>/.local/share/under-claw-work/pgdata
UNDER_CLAW_DB_URL=postgresql://under_claw:<password>@127.0.0.1:5432/under_claw_work?sslmode=disable
```

- 비밀번호는 **hex만** 쓴다. 연결 문자열에 넣을 때 URL 인코딩이 필요 없어진다.
- 환경마다(맥, `astro-hermes`) 각자 이 파일을 둔다. **레포나 대화로 전달하지 않는다.**
- 에이전트는 생성 후 **비밀번호를 화면·로그·커밋 메시지에 출력하지 않는다.**
  사용자에게는 경로까지만 보고한다.

불러오기:

```sh
set -a; . ~/.config/under-claw-work/db.env; set +a
```

## 스키마 적용 방식

`docker/compose.yaml`이 `schema/` 디렉터리를 컨테이너의 `/docker-entrypoint-initdb.d`에 읽기 전용으로 마운트한다.
**데이터 디렉터리가 비어 있는 최초 기동에서만** `*.sql`이 파일명 순서대로 자동 적용된다.

이미 데이터가 있는 상태에서는 자동 적용되지 않는다. 이후 변경은 수동으로 적용한다.

```sh
set -a; . ~/.config/under-claw-work/db.env; set +a
docker exec -i -e PGPASSWORD="$POSTGRES_PASSWORD" under-claw-db \
  psql -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -f - < schema/002_xxx.sql
```

- 파일명은 `schema/NNN_설명.sql`. **적용된 파일은 수정하지 않는다.**
- `002` 이상이 처음 생길 때 적용 이력 테이블을 함께 도입한다.

## 검증

```sh
set -a; . ~/.config/under-claw-work/db.env; set +a
psql_in() { docker exec -i -e PGPASSWORD="$POSTGRES_PASSWORD" under-claw-db \
              psql -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -qtAX "$@"; }

psql_in -c "\dt"                       # 테이블 13개
psql_in -c "\dT"                       # 열거형 4개
psql_in -c "\dv"                       # 뷰 1개 (task_queue)
psql_in -c "SELECT count(*) FROM task;"
```

기대되는 테이블 13개:

```
domain               milestone            task
environment          model                reference
task_model           task_link            task_target
task_run             task_reference       domain_reference
milestone_reference
```

> **접속 시 `-h 127.0.0.1`을 반드시 준다.** 최초 기동 중 postgres는 초기화 스크립트를 도는 동안
> 임시 서버를 유닉스 소켓으로만 띄운다(`listen_addresses=''`). 소켓 기준 `pg_isready`는
> 초기화가 끝나기 전에도 통과하므로, TCP 질의가 통해야 준비 완료로 판정해야 한다.

## 초기 데이터

구조만으로는 `task`를 넣을 수 없다. 환경과 도메인이 먼저 있어야 한다.

```sql
INSERT INTO environment (id, name, kind) VALUES
  ('mac',          'MacBook 로컬',  'local'),
  ('astro-hermes', 'astro hermes',  'remote');

INSERT INTO model (id, name, vendor) VALUES
  ('claude-opus-5', 'Claude Opus 5', 'anthropic');

INSERT INTO domain (id, name) VALUES
  ('ff-genius',    'ff-genius'),
  ('dgdr',         'dgdr'),
  ('astro',        'astro'),
  ('personal-d2r', 'personal / d2r'),
  ('personal-d4',  'personal / d4');
```

도메인의 `objectives` / `common_notes` / `constraint_notes`는 사용자가 채운다.
비어 있어도 동작하지만, 자동 처리(`task.auto`)를 쓰려면 채워져 있어야 한다.

## id 규칙

기존 work-log 규칙을 계승한다. **발급 시점에 확정되고 이후 변경하지 않는다.**

| 대상 | 형식 | 예 |
|---|---|---|
| task | `PT-{YYYYMMDD}-{도메인약어}-{2자리 순번}` | `PT-20260722-ffg-03` |
| domain | 소문자 슬러그 | `ff-genius` |
| milestone | `{도메인약어}-{슬러그}` | `ffg-1.2-dev-task` |
| reference | `REF-{슬러그}` | `REF-eslitigation-api` |

도메인 약어: `ff-genius→ffg`, `dgdr→dgdr`, `astro→astro`, `personal-d2r→d2r`, `personal-d4→d4`

```sql
SELECT coalesce(max(substring(id from '\d+$')::int), 0) + 1
  FROM task
 WHERE id LIKE 'PT-20260722-ffg-%';
```

## 운영

```sh
set -a; . ~/.config/under-claw-work/db.env; set +a
COMPOSE="docker compose --env-file $HOME/.config/under-claw-work/db.env -f docker/compose.yaml"

$COMPOSE ps                 # 상태
$COMPOSE logs -f db         # 로그
$COMPOSE restart db         # 재시작
$COMPOSE down               # 중지 (데이터는 남는다)
```

### 백업

```sh
docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" under-claw-db \
  pg_dump -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists \
  > "backup-$(date +%Y%m%d).sql"
```

백업 파일은 **초안 전문이 들어 있는 실데이터**다. 레포에 두지 않는다.

### 완전 제거

```sh
$COMPOSE down
rm -rf "$UNDER_CLAW_DATA_DIR"                 # 데이터가 사라진다
rm -f ~/.config/under-claw-work/db.env        # 접속정보가 사라진다
```

## 원격 접근

기본값은 **루프백 전용**이다. `astro-hermes` 같은 원격 환경이 이 DB에 붙어야 한다면
`POSTGRES_BIND`를 바꾸는 것만으로는 안 된다. 다음이 함께 결정되어야 한다.

- 전송 구간 암호화 (TLS 또는 SSH 터널 / VPN)
- 접근 허용 대상 제한 (방화벽, `pg_hba.conf`)
- 원격 환경의 접속정보 배포 경로 — **레포를 경유하지 않는 방법으로**

정해지기 전까지는 루프백 유지가 안전한 기본값이다.

## 검증 이력

`001_init.sql`과 `setup.sh`는 macOS / Docker 29.5.3 / `postgres:16-alpine` 환경에서 실행 검증했다.

- 클린 상태에서 `setup.sh` 1회 실행 → 테이블 13 · 열거형 4 · 뷰 1 자동 적용
- 제약 동작 확인 — 도메인 불일치 마일스톤, 도메인 없는 마일스톤, 자기참조 상위,
  내용 없는 참고자료, 정의되지 않은 상태값 전부 거부됨
- 컨테이너 완전 제거 후 재기동 → 투입한 데이터 잔존 (볼륨 마운트 동작 확인)
- 재실행 시 접속정보 파일 해시 불변 (재실행 안전성 확인)
- 포트가 `127.0.0.1:5432`에만 바인딩됨을 `lsof`로 확인

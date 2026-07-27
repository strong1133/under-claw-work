#!/usr/bin/env bash
#
# under-claw-work 데이터 저장소 구축
#
#   1. 접속정보 생성 (없을 때만) — ~/.config/under-claw-work/db.env, 권한 600
#   2. 데이터 디렉터리 생성
#   3. PostgreSQL 컨테이너 기동
#   4. schema/*.sql 적용 확인 (최초 기동 시 자동, 아니면 수동 적용)
#   5. 검증 결과 출력
#
# 몇 번을 실행해도 안전하다. 이미 있는 접속정보와 데이터는 건드리지 않는다.
# 비밀번호는 어떤 경우에도 화면에 출력하지 않는다.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="${HOME}/.config/under-claw-work"
ENV_FILE="${CONFIG_DIR}/db.env"
COMPOSE_FILE="${REPO_DIR}/docker/compose.yaml"

DEFAULT_DB="under_claw_work"
DEFAULT_USER="under_claw"
DEFAULT_PORT="5432"
DEFAULT_BIND="127.0.0.1"
DEFAULT_DATA_DIR="${HOME}/.local/share/under-claw-work/pgdata"

die() { printf '오류: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }

# ── 0. 사전 확인 ─────────────────────────────────────────────
command -v docker >/dev/null 2>&1 || die "docker 를 찾을 수 없다."
docker compose version >/dev/null 2>&1 || die "docker compose (v2) 를 찾을 수 없다."
docker info >/dev/null 2>&1 || die "docker 데몬이 실행 중이 아니다."
[ -f "${REPO_DIR}/schema/001_init.sql" ] || die "schema/001_init.sql 이 없다."

# ── 1. 접속정보 ──────────────────────────────────────────────
if [ -f "${ENV_FILE}" ]; then
  say "접속정보: 기존 파일 사용 (${ENV_FILE})"
else
  command -v openssl >/dev/null 2>&1 || die "openssl 이 없어 비밀번호를 생성할 수 없다."
  mkdir -p "${CONFIG_DIR}"
  chmod 700 "${CONFIG_DIR}"

  # hex 만 사용한다 — 연결 문자열에 넣을 때 URL 인코딩이 필요 없다
  password="$(openssl rand -hex 24)"

  umask 077
  cat > "${ENV_FILE}" <<EOF
# under-claw-work 데이터 저장소 접속정보
# 이 파일은 절대 저장소에 커밋하지 않는다.
POSTGRES_DB=${DEFAULT_DB}
POSTGRES_USER=${DEFAULT_USER}
POSTGRES_PASSWORD=${password}
POSTGRES_PORT=${DEFAULT_PORT}
POSTGRES_BIND=${DEFAULT_BIND}
UNDER_CLAW_DATA_DIR=${DEFAULT_DATA_DIR}
UNDER_CLAW_DB_URL=postgresql://${DEFAULT_USER}:${password}@${DEFAULT_BIND}:${DEFAULT_PORT}/${DEFAULT_DB}?sslmode=disable
EOF
  unset password
  chmod 600 "${ENV_FILE}"
  say "접속정보: 신규 생성 (${ENV_FILE}, 권한 600)"
fi

set -a
# shellcheck disable=SC1090
. "${ENV_FILE}"
set +a

: "${UNDER_CLAW_DATA_DIR:?db.env 에 UNDER_CLAW_DATA_DIR 가 없다}"
: "${POSTGRES_PASSWORD:?db.env 에 POSTGRES_PASSWORD 가 없다}"

# ── 2. 데이터 디렉터리 ───────────────────────────────────────
mkdir -p "${UNDER_CLAW_DATA_DIR}"
say "데이터 디렉터리: ${UNDER_CLAW_DATA_DIR}"

# ── 3. 기동 ──────────────────────────────────────────────────
say "컨테이너 기동 중..."
docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" up -d >/dev/null

psql_in() { docker exec -i -e PGPASSWORD="${POSTGRES_PASSWORD}" under-claw-db \
              psql -h 127.0.0.1 -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -qtAX "$@"; }

# 최초 기동 시 postgres 는 초기화 스크립트를 도는 동안 임시 서버를 유닉스 소켓으로만 띄운다
# (listen_addresses=''). 따라서 소켓 기준 pg_isready 는 초기화 도중에도 성공해 버린다.
# TCP 로 실제 질의가 통해야 초기화가 끝난 것이므로 그것을 대기 조건으로 쓴다.
printf '기동 대기'
for _ in $(seq 1 60); do
  if psql_in -c 'SELECT 1' >/dev/null 2>&1; then
    ready=1; break
  fi
  printf '.'; sleep 1
done
printf '\n'
[ "${ready:-0}" = "1" ] || die "기동 대기 시간 초과. docker logs under-claw-db 로 확인한다."

# ── 4. 스키마 ────────────────────────────────────────────────
tables="$(psql_in -c "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE';")"

if [ "${tables}" = "0" ]; then
  say "스키마: 미적용 상태 — schema/001_init.sql 적용"
  psql_in -v ON_ERROR_STOP=1 -f - < "${REPO_DIR}/schema/001_init.sql" >/dev/null
  tables="$(psql_in -c "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE';")"
else
  say "스키마: 이미 적용됨 (최초 기동 시 자동 적용)"
fi

enums="$(psql_in -c "SELECT count(*) FROM pg_type t JOIN pg_namespace n ON n.oid=t.typnamespace WHERE n.nspname='public' AND t.typtype='e';")"
views="$(psql_in -c "SELECT count(*) FROM information_schema.views WHERE table_schema='public';")"
tasks="$(psql_in -c "SELECT count(*) FROM task;")"

# ── 5. 결과 ──────────────────────────────────────────────────
cat <<EOF

구축 완료

  컨테이너   under-claw-db (postgres:16-alpine)
  접속       ${POSTGRES_BIND}:${POSTGRES_PORT} / DB ${POSTGRES_DB} / 사용자 ${POSTGRES_USER}
  데이터     ${UNDER_CLAW_DATA_DIR}
  접속정보   ${ENV_FILE}
  스키마     테이블 ${tables} · 열거형 ${enums} · 뷰 ${views}
  task       ${tasks}건

  사용:
    set -a; . ${ENV_FILE}; set +a
    psql "\$UNDER_CLAW_DB_URL"

  중지: docker compose --env-file ${ENV_FILE} -f ${COMPOSE_FILE} down
  제거: 위 명령 후 rm -rf ${UNDER_CLAW_DATA_DIR}   (데이터가 사라진다)
EOF

[ "${tables}" = "13" ] || die "테이블 수가 13이 아니다 (${tables}). 스키마 적용을 확인한다."

#!/usr/bin/env bash
set -euo pipefail

workspace="${1:-}"
environment_id="${2:-}"
adapter_id="${3:-}"
interval="${4:-15}"
install_root="${UNDER_CLAW_WORK_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/under-claw-work}"
default_worklog="$install_root/bin/worklog"
if [[ ! -x "$default_worklog" ]]; then
  default_worklog="$(command -v worklog || true)"
fi
worklog_bin="${UNDER_CLAW_WORKLOG_BIN:-$default_worklog}"
[[ "$workspace" = /* && -d "$workspace/.git" ]] || {
  echo "auto-meta-watch requires an absolute Git workspace" >&2; exit 64;
}
[[ "$environment_id" =~ ^ENV-[A-Za-z0-9._-]+$ ]] || {
  echo "Invalid environment id" >&2; exit 64;
}
[[ "$adapter_id" =~ ^[A-Za-z0-9._-]+$ ]] || {
  echo "Invalid adapter id" >&2; exit 64;
}
[[ "$interval" =~ ^[0-9]+$ && "$interval" -ge 5 ]] || {
  echo "Interval must be at least 5 seconds" >&2; exit 64;
}
[[ -x "$worklog_bin" ]] || { echo "worklog is unavailable" >&2; exit 66; }
mkdir -p "$workspace/.worklog"
lock="$workspace/.worklog/auto-meta-watch.lock"
exec 9>"$lock"
if ! flock -n 9; then
  echo "An auto Meta watcher already owns this workspace" >&2
  exit 75
fi
while :; do
  started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if output="$("$worklog_bin" auto-meta-next \
    "$workspace" "$environment_id" "$adapter_id" 2>&1)"; then
    printf '%s %s\n' "$started" "$output"
  else
    status=$?
    printf '%s auto_meta=error exit=%s\n' "$started" "$status" >&2
  fi
  sleep "$interval"
done

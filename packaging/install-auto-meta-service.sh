#!/usr/bin/env bash
set -euo pipefail

workspace="${1:-}"
environment_id="${2:-}"
adapter_id="${3:-hermes-meta-prompt}"
interval="${4:-15}"
install_root="${UNDER_CLAW_WORK_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/under-claw-work}"
watch_script="$install_root/packaging/auto-meta-watch.sh"
default_worklog="$install_root/bin/worklog"
if [[ ! -x "$default_worklog" ]]; then
  default_worklog="$(command -v worklog || true)"
fi
worklog_bin="${UNDER_CLAW_WORKLOG_BIN:-$default_worklog}"
hermes_bin="${UNDER_CLAW_HERMES_BIN:-$(command -v hermes || true)}"
hermes_home="${HERMES_HOME:-$HOME/.hermes}"
for value in "$workspace" "$environment_id" "$adapter_id" "$interval" \
  "$install_root" "$worklog_bin" "$hermes_bin" "$hermes_home"; do
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || {
    echo "Unit values may not contain newlines" >&2
    exit 64
  }
done
[[ "$(uname -s)" == Linux && -d /run/systemd/system ]] || {
  echo "Automatic service installation currently requires Linux systemd" >&2; exit 69;
}
[[ "$workspace" = /* && -d "$workspace" ]] &&
  [[ "$(git -C "$workspace" rev-parse --is-inside-work-tree 2>/dev/null || true)" == true ]] || {
  echo "install-auto-meta-service requires an absolute Git workspace" >&2
  exit 64
}
[[ -x "$watch_script" && -x "$worklog_bin" && -x "$hermes_bin" ]] || {
  echo "Installed watcher, worklog, or Hermes executable is unavailable" >&2
  exit 66
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
quote_unit() {
  local value="$1"
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || {
    echo "Unit values may not contain newlines" >&2
    return 64
  }
  value="${value//%/%%}"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}
quoted_hermes_home="$(quote_unit "$hermes_home")"
quoted_hermes_bin="$(quote_unit "$hermes_bin")"
quoted_worklog_bin="$(quote_unit "$worklog_bin")"
quoted_watch_script="$(quote_unit "$watch_script")"
quoted_workspace="$(quote_unit "$workspace")"
quoted_environment_id="$(quote_unit "$environment_id")"
quoted_adapter_id="$(quote_unit "$adapter_id")"
quoted_interval="$(quote_unit "$interval")"
unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
unit="$unit_dir/under-claw-auto-meta.service"
mkdir -p "$unit_dir"
cat > "$unit" <<EOF
[Unit]
Description=Under Claw Work automatic Meta Prompt watcher
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=HERMES_HOME=$quoted_hermes_home
Environment=UNDER_CLAW_HERMES_BIN=$quoted_hermes_bin
Environment=UNDER_CLAW_WORKLOG_BIN=$quoted_worklog_bin
ExecStart=$quoted_watch_script $quoted_workspace $quoted_environment_id $quoted_adapter_id $quoted_interval
Restart=on-failure
RestartSec=10
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
systemctl --user enable --now under-claw-auto-meta.service
systemctl --user --no-pager --full status under-claw-auto-meta.service

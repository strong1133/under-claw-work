#!/usr/bin/env bash
set -euo pipefail

install_root="${UNDER_CLAW_WORK_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/under-claw-work}"
previous="$install_root.previous"
[[ "$install_root" = /* ]] || { echo "Install root must be absolute" >&2; exit 64; }
case "$install_root" in /|"$HOME"|"${HOME}/"|"") echo "Unsafe install root" >&2; exit 64 ;; esac
parent="$(dirname "$install_root")"
swap="$parent/.under-claw-rollback.$$"
lock="$parent/.under-claw-update.lock"
if ! mkdir "$lock" 2>/dev/null; then
  echo "Another Under Claw Work update is active" >&2
  exit 75
fi
trap 'rmdir "$lock" 2>/dev/null || true' EXIT
[[ -d "$install_root" && -d "$previous" ]] || {
  echo "No previous Under Claw Work installation is available" >&2; exit 66;
}
previous_cli="$previous/bin/worklog"
[[ -x "$previous_cli" ]] || previous_cli="$previous/bin/worklog.exe"
[[ -x "$previous_cli" ]] || { echo "Previous installation is invalid" >&2; exit 65; }
if ! UNDER_CLAW_WORK_HOME="$previous" "$previous_cli" --help >/dev/null 2>&1; then
  echo "Previous installation failed health check" >&2
  exit 70
fi
mv "$install_root" "$swap"
if mv "$previous" "$install_root"; then
  mv "$swap" "$previous"
  echo "Under Claw Work rolled back; replaced version retained for re-apply."
else
  mv "$swap" "$install_root"
  echo "Rollback swap failed; active installation restored" >&2
  exit 71
fi

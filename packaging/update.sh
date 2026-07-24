#!/usr/bin/env bash
set -euo pipefail

release="${1:-}"
install_root="${UNDER_CLAW_WORK_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/under-claw-work}"
[[ -d "$release" && -f "$release/release-manifest.tsv" ]] || {
  echo "Usage: update.sh <extracted-release-directory>" >&2; exit 64;
}
[[ "$release" = /* && "$install_root" = /* ]] || {
  echo "Release and install roots must be absolute" >&2; exit 64;
}
case "$install_root" in /|"$HOME"|"${HOME}/"|"") echo "Unsafe install root" >&2; exit 64 ;; esac
parent="$(dirname "$install_root")"
mkdir -p "$parent"
lock="$parent/.under-claw-update.lock"
if ! mkdir "$lock" 2>/dev/null; then
  echo "Another Under Claw Work update is active" >&2
  exit 75
fi
cleanup_lock() { rmdir "$lock" 2>/dev/null || true; }
trap cleanup_lock EXIT
installed_cli="$install_root/bin/worklog"
[[ -x "$installed_cli" ]] || installed_cli="$install_root/bin/worklog.exe"
[[ -x "$installed_cli" ]] || { echo "Existing installation not found" >&2; exit 66; }
trusted_verifier="$install_root/packaging/verify-release.sh"
[[ -f "$trusted_verifier" && ! -L "$trusted_verifier" ]] || {
  echo "Trusted installed release verifier is unavailable" >&2; exit 65;
}
bash "$trusted_verifier" "$release"

candidate="$(mktemp -d "$parent/.under-claw-update.XXXXXX")"
backup="$parent/.under-claw-backup.$$"
previous="$install_root.previous"
cleanup() {
  if [[ -d "$candidate" ]]; then rm -rf "$candidate"; fi
  rmdir "$lock" 2>/dev/null || true
  return 0
}
trap cleanup EXIT
cp -R "$install_root/." "$candidate/"
cli_source="$release/build/cli/bundle/bin/worklog"
[[ -f "$cli_source" ]] || cli_source="$release/build/cli/bundle/bin/worklog.exe"
[[ -f "$cli_source" ]] || { echo "Release CLI is missing" >&2; exit 65; }
cli_name="$(basename "$cli_source")"
rm -f "$candidate/bin/worklog" "$candidate/bin/worklog.exe"
install -m 0755 "$cli_source" "$candidate/bin/$cli_name"
rm -rf "$candidate/lib"
[[ ! -d "$release/build/cli/bundle/lib" ]] ||
  cp -R "$release/build/cli/bundle/lib" "$candidate/lib"
for directory in app packaging bundled-skills skills personas; do
  rm -rf "$candidate/$directory"
  cp -RL "$release/$directory" "$candidate/$directory"
done
for file in UNSIGNED-NOTICE.txt ACCEPTED-RUNTIMES.txt RELEASE-VERSION.txt \
  README.txt release-manifest.tsv; do
  cp "$release/$file" "$candidate/$file"
done

if [[ ! -f "$candidate/app/.under-claw-app-health" ]] ||
  ! UNDER_CLAW_WORK_HOME="$candidate" \
    "$candidate/bin/$cli_name" --help >/dev/null 2>&1; then
  echo "Updated runtime failed health check; existing installation preserved" >&2
  exit 70
fi

mv "$install_root" "$backup"
if ! mv "$candidate" "$install_root"; then
  mv "$backup" "$install_root"
  echo "Update swap failed; previous installation restored" >&2
  exit 71
fi

old_previous="$parent/.under-claw-previous.$$"
restore_active() {
  local failed_candidate="$parent/.under-claw-failed-candidate.$$"
  if mv "$install_root" "$failed_candidate" && mv "$backup" "$install_root"; then
    if [[ -d "$old_previous" ]]; then mv "$old_previous" "$previous"; fi
    rm -rf "$failed_candidate"
  fi
}
if [[ -d "$previous" ]] && ! mv "$previous" "$old_previous"; then
  restore_active
  echo "Could not stage the existing rollback copy; update reverted" >&2
  exit 71
fi
if ! mv "$backup" "$previous"; then
  restore_active
  echo "Could not retain the previous installation; update reverted" >&2
  exit 71
fi
rm -rf "$old_previous"
echo "Under Claw Work updated from an unsigned archive."
echo "Manifest hashes provide integrity, not publisher authenticity."
echo "Previous installation retained for: worklog update-rollback"
